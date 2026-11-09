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
            # 文件格式: magic(4) + version(1) + reserved(3) + header_len_le(4) = 12 bytes
            version, _reserved = struct.unpack('<B3s', f.read(4))
            (header_len,) = struct.unpack('<I', f.read(4))
            # 跳过 SPS/PPS header（已写入文件但 mux 时 ffmpeg 需要从 extra_data 读）
            if header_len > 0:
                f.seek(header_len, 1)  # skip header
            fmt = 'video'
        elif magic == b'SDFA':
            # 文件格式: magic(4) + version(1) + reserved(3) = 8 bytes (无 header_len)
            version, _reserved = struct.unpack('<B3s', f.read(4))
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
    读取 dump 文件最后一帧的 PTS。
    策略：正向扫描所有帧头（跳过 data），返回最后一帧 PTS。
    O(file_size) 但正确——原反向扫描在 frame data 中随机找 "看起来合法" 的 4 字节当 header，
    返回垃圾 PTS（如 1.4e19 这种 >2^63 的值），触发 lib-monitor 的 pts-jump 误判。
    返回 last_pts (int, us) 或 None。
    """
    FRAME_HDR_SIZE = 12    # size_le(4) + pts_le(8)
    MAX_FRAME_SIZE = 16 * 1024 * 1024  # 16MB,单帧不可能超过（sanity check 防越界）

    try:
        with open(path, 'rb') as f:
            magic = f.read(4)
            if magic not in (b'SDFV', b'SDFA'):
                return None
            version, _reserved = struct.unpack('<B3s', f.read(4))
            data_start = 12  # HEADER_MAGIC_SIZE
            if magic == b'SDFV':
                (header_len,) = struct.unpack('<I', f.read(4))
                data_start += header_len

            f.seek(data_start)
            last_pts = None
            while True:
                hdr = f.read(FRAME_HDR_SIZE)
                if len(hdr) < FRAME_HDR_SIZE:
                    break
                frame_size, pts_us = struct.unpack('<IQ', hdr)
                # sanity check：frame_size 应是合理 H.264/AAC 帧大小
                if frame_size <= 0 or frame_size > MAX_FRAME_SIZE:
                    return last_pts  # 损坏了,返回到目前为止的 last_pts
                # 跳过 frame data
                f.seek(frame_size, 1)
                last_pts = pts_us
            return last_pts
    except (OSError, struct.error):
        return None


def detect_first_keyframe_index(sdfv_path: str) -> int:
    """Scan SDFV file and return index of first IDR frame (NAL type 5/19/20)."""
    with open(sdfv_path, 'rb') as f:
        magic = f.read(4)
        if magic != b'SDFV':
            raise ValueError(f"Not SDFV file: {magic!r}")
        version, _reserved = struct.unpack('<B3s', f.read(4))
        (header_len,) = struct.unpack('<I', f.read(4))
        if header_len > 0:
            f.seek(header_len, 1)

        frame_idx = 0
        while True:
            hdr = f.read(12)
            if len(hdr) < 12:
                break
            frame_size, pts_us = struct.unpack('<IQ', hdr)
            data = f.read(frame_size)
            if len(data) < frame_size:
                break
            # Check first NAL unit type
            if data and len(data) >= 5:
                # NAL header: forbidden_zero_bit(1) + nal_ref_idc(2) + nal_unit_type(5)
                nal_type = data[0] & 0x1F
                # IDR types: 5 (H.264), 19 (HEVC IDR_W_RADL), 20 (HEVC IDR_N_LP)
                if nal_type in (5, 19, 20):
                    return frame_idx
            frame_idx += 1
    return -1


def main():
    import argparse
    parser = argparse.ArgumentParser(description='Parse SDFV/SDFA dump to .raw + .pts')
    parser.add_argument('input', help='Input dump file')
    parser.add_argument('pts_offset', nargs='?', type=int, default=0, help='PTS offset in microseconds')
    parser.add_argument('out_prefix', nargs='?', default=None,
                        help='Output prefix for .raw/.pts (default: <input> minus extension)')
    parser.add_argument('--last-pts-only', action='store_true', help='Only print last frame PTS')
    parser.add_argument('--detect-first-keyframe', action='store_true', help='Detect first IDR frame index and print it')
    args = parser.parse_args()

    inp = args.input
    pts_offset = args.pts_offset
    last_only = args.last_pts_only
    detect_keyframe = args.detect_first_keyframe

    # v4.3.9: 输出前缀可显式指定 — 视频/音频提取共用同一目录时避免互相覆盖同名文件
    base = args.out_prefix if args.out_prefix else os.path.splitext(inp)[0]
    raw_out = base + '.raw'
    pts_out = base + '.pts'

    if detect_keyframe:
        idx = detect_first_keyframe_index(inp)
        print(idx)
        return

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