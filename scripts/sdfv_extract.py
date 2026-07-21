#!/usr/bin/env python3
"""
SDFV/SDFA dump 解析器（StreamDumper Format with PTS）

文件格式:
  视频 (SDFV):
    magic(4) = b'SDFV'
    version(1) + reserved(3)
    header_len_le(4)
    header_data (SPS/PPS, header_len bytes)
    每帧: frame_size_le(4) + pts_le(8) + frame_data(frame_size bytes)

  音频 (SDFA):
    magic(4) = b'SDFA'
    version(1) + reserved(3)
    每帧: frame_size_le(4) + pts_le(8) + frame_data(frame_size bytes)

输出:
  - <prefix>.raw:  拼接所有 frame_data (无 PTS, 兼容老格式)
  - <prefix>.pts:  每帧 PTS（微秒），一行一个，按帧顺序
"""
import sys
import struct
import os


def parse_dump(path):
    """Parse SDFV/SDFA dump file. Yields (frame_data, pts_us)."""
    with open(path, 'rb') as f:
        magic = f.read(4)
        if magic == b'SDFV':
            version, _reserved = struct.unpack('<BBxxx', f.read(4))
            (header_len,) = struct.unpack('<I', f.read(4))
            # 跳过 SPS/PPS header（已写入文件但 mux 时 ffmpeg 需要从 extra_data 读）
            if header_len > 0:
                f.seek(header_len, 1)  # skip header
            fmt = 'video'
        elif magic == b'SDFA':
            version, _reserved = struct.unpack('<BBxxx', f.read(4))
            fmt = 'audio'
        else:
            print(f"ERROR: not a SDF dump (magic={magic!r})", file=sys.stderr)
            sys.exit(1)

        if version != 1:
            print(f"ERROR: unsupported version {version}", file=sys.stderr)
            sys.exit(1)

        frame_count = 0
        while True:
            hdr = f.read(12)  # frame_size(4) + pts(8)
            if len(hdr) < 12:
                break
            frame_size, pts_us = struct.unpack('<IQ', hdr)
            data = f.read(frame_size)
            if len(data) < frame_size:
                print(f"WARN: truncated frame {frame_count} (need {frame_size}, got {len(data)})", file=sys.stderr)
                break
            yield data, pts_us
            frame_count += 1
        return frame_count


def read_last_pts(path):
    """
    快速读取 dump 文件最后一帧的 PTS。
    策略：先读文件头获取 header_len，然后只扫描文件尾部 1MB 范围（覆盖最后 ~50 帧），
    找到最后一帧的 [size, pts] 头，跳过其 data，拿到下一帧头 → 最后一帧的 pts。
    返回 (last_pts, prev_pts) 或 None（无帧）。
    """
    HEADER_MAGIC_SIZE = 12  # magic(4) + ver(1) + res(3) + header_len_le(4)
    FRAME_HDR_SIZE = 12    # size_le(4) + pts_le(8)
    MAX_FRAME_SIZE = 2 * 1024 * 1024  # 2MB, h264 single frame 几乎不可能超过
    TAIL_SCAN = 1024 * 1024  # 从尾部扫 1MB

    try:
        with open(path, 'rb') as f:
            magic = f.read(4)
            if magic not in (b'SDFV', b'SDFA'):
                return None
            version, _reserved = struct.unpack('<BBxxx', f.read(4))
            if magic == b'SDFV':
                (header_len,) = struct.unpack('<I', f.read(4))
                data_start = HEADER_MAGIC_SIZE + header_len
            else:
                data_start = HEADER_MAGIC_SIZE

            file_size = f.seek(0, 2)  # 末尾
            if file_size < data_start + FRAME_HDR_SIZE:
                return None

            # 读文件尾部 TAIL_SCAN 字节（不足则全读）
            tail_size = min(TAIL_SCAN, file_size - data_start)
            f.seek(file_size - tail_size)
            tail = f.read(tail_size)

            # 从尾往前扫：找最后一帧的 [size, pts]
            # 帧头格式 [size:4][pts:8], 从某个 offset 开始每帧 12+size bytes
            # 倒序：从 tail_size 往前找 size 字段（4 字节 LE），size 必须 <= MAX_FRAME_SIZE
            pos = len(tail)
            last_frame_pts = None
            prev_frame_pts = None

            # 从尾部往前逐帧反向扫描
            # 边界处理：如果最后一帧不完整，会被部分读取。我们读 size 不合法就丢弃。
            while pos > 0:
                if pos < FRAME_HDR_SIZE:
                    break
                hdr_off = pos - FRAME_HDR_SIZE
                size_bytes = tail[hdr_off:hdr_off+4]
                if len(size_bytes) < 4:
                    break
                (frame_size,) = struct.unpack('<I', size_bytes)
                if frame_size == 0 or frame_size > MAX_FRAME_SIZE:
                    # size 无效 → 这个 hdr_off 不是真正的帧头，往前退 1 字节重试
                    pos -= 1
                    continue
                # 读 pts
                pts_bytes = tail[hdr_off+4:hdr_off+12]
                if len(pts_bytes) < 8:
                    break
                (_, frame_pts) = struct.unpack('<IQ', tail[hdr_off:hdr_off+12])
                if last_frame_pts is None:
                    last_frame_pts = frame_pts
                    prev_frame_pts = frame_pts
                else:
                    prev_frame_pts = frame_pts
                # 往前退 12 + frame_size
                pos = hdr_off - frame_size
                if pos < 0:
                    break
                # 只拿最近两帧
                if prev_frame_pts is not None and prev_frame_pts != last_frame_pts:
                    break

            return last_frame_pts
    except (OSError, struct.error):
        return None


def main():
    if len(sys.argv) not in (2, 3, 4):
        print(f"Usage: {sys.argv[0]} <input.dump> [pts_offset_us] [--last-pts-only]", file=sys.stderr)
        sys.exit(1)
    inp = sys.argv[1]
    pts_offset = 0
    last_only = False
    for arg in sys.argv[2:]:
        if arg == '--last-pts-only':
            last_only = True
        else:
            pts_offset = int(arg)
    base, _ext = os.path.splitext(inp)
    raw_out = base + '.raw'
    pts_out = base + '.pts'

    n_frames = 0
    first_pts = None
    last_pts = None

    if last_only:
        # 快速读取最后一帧 PTS（不解析整个文件）
        last_pts = read_last_pts(inp)
        if last_pts is not None:
            print(f"{last_pts + pts_offset}")
        else:
            sys.exit(2)  # 无帧可读
        return

    with open(raw_out, 'wb') as f_raw, open(pts_out, 'w') as f_pts:
        for data, pts in parse_dump(inp):
            f_raw.write(data)
            f_pts.write(f"{pts + pts_offset}\n")
            if first_pts is None:
                first_pts = pts + pts_offset
            last_pts = pts + pts_offset
            n_frames += 1

    if first_pts is not None and last_pts is not None:
        dur_s = (last_pts - first_pts) / 1_000_000.0
        print(f"frames={n_frames} first_pts={first_pts}us last_pts={last_pts}us "
              f"span={dur_s:.3f}s -> {raw_out} + {pts_out}", file=sys.stderr)


if __name__ == '__main__':
    main()