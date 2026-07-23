#!/usr/bin/env python3
"""
SDFV/SDFA dump 解析器（StreamDumper Format with PTS）

文件格式 (StreamDumper 写出的真实格式):
  视频 (SDFV):
    magic(4) = b'SDFV'
    version(1) = 0x01
    reserved(3)
    header_len_le(4)
    header_data (SPS/PPS, header_len bytes)
    每帧:
      frame_size_le(4)   # 本帧数据字节数（仅 frame_data 部分，不含 hdr）
      pts_le(8)          # firefox sample PTS (microseconds)
      frame_data(frame_size bytes)

  音频 (SDFA):
    magic(4) = b'SDFA'
    version(1) = 0x01
    reserved(3)
    每帧:
      frame_size_le(4)
      pts_le(8)
      frame_data(frame_size bytes)  # ADTS

输出:
  - <prefix>.raw:  拼接所有 frame_data（按原始 mux 顺序，不带 PTS）
  - <prefix>.pts:  每帧 PTS（微秒），一行一个

附加:
  --last-pts-only  → 只打印最后帧 PTS, fast path
  --first-keyframe  → 打出首个 IDR/keyframe 的 (idx, pts_us) 一行（用于 mux rebase 锚点）
  --pts-offset N    → 读 pts 时整体加 N 微秒
"""
import sys
import struct
import os
import re


MAGIC_V = b"SDFV"
MAGIC_A = b"SDFA"


def _parse_header(f):
    """读 12 字节 magic + 返回 header/data 起始偏移."""
    magic = f.read(4)
    if magic == MAGIC_V:
        (version,) = struct.unpack("<B", f.read(1))
        f.read(3)
        (header_len,) = struct.unpack("<I", f.read(4))
        data_start = 12 + header_len
        return "video", version, data_start
    elif magic == MAGIC_A:
        (version,) = struct.unpack("<B", f.read(1))
        f.read(3)
        data_start = 8
        return "audio", version, data_start
    else:
        print(f"ERROR: not a SDF dump (magic={magic!r})", file=sys.stderr)
        sys.exit(1)


def iter_frames(path):
    """Yield (kind, size, pts_us, frame_bytes) tuples."""
    with open(path, "rb") as f:
        kind, version, data_start = _parse_header(f)
        if version != 1:
            print(f"ERROR: unsupported version {version}", file=sys.stderr)
            sys.exit(1)
        f.seek(data_start)
        while True:
            hdr = f.read(12)
            if len(hdr) < 12:
                return
            size, pts_us = struct.unpack("<IQ", hdr)
            data = f.read(size)
            if len(data) < size:
                return
            yield kind, size, pts_us, data


def read_last_pts(path):
    """Fast path: 只读最后一帧 PTS（不解析整个文件）.

    Strategy: 从末尾向前滚扫 8 字节候选，看是不是合法 PTS 范围
    (0 < pts < 24h us). 一旦命中, 跳到前一个 frame_hdr 边界（按 size 推算）确认.
    简化（保证近似正确，多数场景足够）：从末尾 - 12 处读 size+pts；接着检查
    pts 范围; 假定此时 size 与文件中 frame_data 一致（实际应快扫整帧).
    """
    MAX_PTS_US = 24 * 3600 * 1000000
    with open(path, "rb") as f:
        kind, version, data_start = _parse_header(f)
        if version != 1:
            return None
        f.seek(0, 2)
        file_size = f.tell()
        # 反向扫 8 字节候选（每个 frame 都有 8 字节 PTS, 随机位置命中率高）
        # 逆向: 一次读 1KB, 假定 frame_data < 1MB (一般不大于 500KB)
        # 真正可靠: 反向循环回 frame_hdr 边界, 需扫整帧到首个 frame_hdr.
        # 这里改用更纯的算法: 顺序扫记录最后帧 PTS. 文件不会超过 GB 级, 几秒内 OK.
        last = None
        for _kind, _size, pts_us, _data in iter_frames(path):
            last = pts_us
        return last


# --- 视频侧 keyframe 检测 ----------------------------------------------------

# H.264 / HEVC 的 NAL unit type (3 bits after SC4/SC3 起始码 byte)
# IDR NAL types:
#   H.264 AVC:  nal_unit_type = 5  (Coded slice of an IDR picture)
#   H.265 HEVC: nal_unit_type = 19 (IDR_W_RADL) or 20 (IDR_N_LP)
# 关键帧标识 (keyframe candidate):
#   SPS/PPS/IDR/VPS — mux 时 PyAV 会按 access unit 自动判定。
# 简化: 我们找第一个 NAL unit_type 5 (AVC) / 19 / 20 (HEVC)
# 即"首个 IDR slice"，等价于"start of new access unit that doesn't depend on prior"。
#
# 这里不解析完整 NAL header (有 emulation prevention byte 问题), 只看 SC4/SC3 起始码后
# 第 1 字节的低 5 bits (AVC) / 有效 bits (HEVC)。

SC4 = b"\x00\x00\x00\x01"
SC3 = b"\x00\x00\x01"

def _split_nalus_in_frame(frame_bytes):
    """把一帧 video data 按 SC3/SC4 切 NAL units; yield (sc_len, nal_header_byte, frame_bytes_in_nal)."""
    positions = []
    i = 0
    n = len(frame_bytes)
    while i < n - 4:
        if frame_bytes[i:i+4] == SC4:
            positions.append((i, 4))
            i += 4
        elif frame_bytes[i:i+3] == SC3:
            positions.append((i, 3))
            i += 3
        else:
            i += 1
    for idx, (pos, sclen) in enumerate(positions):
        end = positions[idx + 1][0] if idx + 1 < len(positions) else n
        nal = frame_bytes[pos + sclen:end]
        if not nal:
            continue
        # 第一个字节是 NAL unit header (AVC: forbidden_zero_bit(1)+nal_ref_idc(2)+nal_unit_type(3))
        # AVC nal_unit_type = nal[0] & 0x1F
        yield nal[0] & 0x1F, nal[:1]


def detect_first_keyframe_index(path):
    """扫描 SDFV 找首个 NAL unit_type 5 / 19 / 20 (H.264/HEVC IDR) 的 frame 索引.
    AV1 / VP9: 跳过, 我们不擅长 NAL-level 检测.
    Returns: (idx, pts_us) or (None, None) if 没找到或非 H.26x.
    """
    is_avc = True  # heuristic, 我们不读 header; 假定 H.264/HEVC 都找 nal_type 5/19/20
    for idx, (kind, size, pts_us, frame_bytes) in enumerate(iter_frames(path)):
        if kind != "video":
            continue
        for nal_type, _hdr in _split_nalus_in_frame(frame_bytes):
            if nal_type in (5, 19, 20):  # IDR
                return idx, pts_us
        # 若已扫几百帧都没 IDR, 大概率不是 H.26x 流, 放弃
        if idx > 2000:
            return None, None
    return None, None


# --- 主入口 -----------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <input.dump> [opts]", file=sys.stderr)
        sys.exit(1)

    inp = sys.argv[1]

    # 解析选项
    pts_offset = 0
    last_only = False
    first_keyframe_only = False
    args = sys.argv[2:]
    while args:
        a = args.pop(0)
        if a == "--last-pts-only":
            last_only = True
        elif a == "--first-keyframe":
            first_keyframe_only = True
        elif a == "--pts-offset":
            pts_offset = int(args.pop(0))
        else:
            print(f"ERROR: unknown arg {a}", file=sys.stderr)
            sys.exit(1)

    base, _ext = os.path.splitext(inp)
    raw_out = base + ".raw"
    pts_out = base + ".pts"

    if last_only:
        last_pts = read_last_pts(inp)
        if last_pts is None:
            sys.exit(2)
        print(f"{last_pts + pts_offset}")
        return

    if first_keyframe_only:
        idx, pts = detect_first_keyframe_index(inp)
        if idx is None:
            print("NONE", file=sys.stderr)
            sys.exit(2)
        print(f"{idx} {pts}")
        return

    n_frames = 0
    first_pts = None
    last_pts = None
    with open(raw_out, "wb") as f_raw, open(pts_out, "w") as f_pts:
        for kind, size, pts_us, data in iter_frames(inp):
            f_raw.write(data)
            f_pts.write(f"{pts_us + pts_offset}\n")
            if first_pts is None:
                first_pts = pts_us + pts_offset
            last_pts = pts_us + pts_offset
            n_frames += 1

    if first_pts is not None and last_pts is not None:
        dur_s = (last_pts - first_pts) / 1_000_000.0
        print(f"frames={n_frames} first_pts={first_pts}us last_pts={last_pts}us "
              f"span={dur_s:.3f}s -> {raw_out} + {pts_out}", file=sys.stderr)


if __name__ == "__main__":
    main()
