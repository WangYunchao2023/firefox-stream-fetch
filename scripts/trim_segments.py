#!/usr/bin/env python3
"""
Trim SDFV dump file by keeping only the main segment.

Prerequisite: caller must ensure ${base}.h264.original exists and contains the
FULL pre-trim dump. capture.sh handles this via `cp -p` before invoking this
script.

Workflow:
  1. Read .pts.final.pts to find main segment boundaries
  2. Read ALL frames from .h264.original into memory
  3. Find first IDR in main segment (必须从 IDR 开始，否则丢 SPS/PPS + 参考帧 → 花屏)
  4. Write frames from first IDR onwards in DTS order (decoder order) to
     temp file, then atomic rename → .h264
     注意：必须 DTS 顺序输出，不是 PTS 顺序。H.264 bitstream 解码依赖 DTS，
     按 PTS 重排会破坏参考帧顺序 → B 帧花屏。

After this, the mux pipeline (capture.sh → mux_to_mp4 → sdfv_extract →
mux_with_pts) can use .h264 directly without any modification.

Usage: trim_segments.py <base_name> [search_dir]
  base_name:   e.g., manual-20260803-113501
  search_dir:  optional directory to search for dump files (defaults to CWD)
"""
import sys
import os
import struct
from pathlib import Path


def read_final_pts(path):
    """Parse .final.pts, return list of (frame_No, pts_us, dts_order, duration_us, size, keyframe)."""
    rows = []
    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split('\t')
            if len(parts) >= 6:
                rows.append((
                    int(parts[0]),    # frame_No
                    int(parts[1]),    # pts_us
                    int(parts[2]),    # dts_order
                    int(parts[3]),    # duration_us
                    int(parts[4]),    # size
                    int(parts[5]),    # keyframe
                ))
    return rows


def split_segments_by_frame_no(rows):
    """Split rows into segments where frame_No restarts at 1."""
    segments = []
    current = []
    for r in rows:
        frame_no = r[0]
        if frame_no == 1 and current:
            segments.append(current)
            current = []
        current.append(r)
    if current:
        segments.append(current)
    return segments


def pick_main_segment(segments):
    """Return (main_segment, main_index) where main is longest by frame count."""
    if not segments:
        return None, -1
    best_idx = max(range(len(segments)), key=lambda i: len(segments[i]))
    return segments[best_idx], best_idx


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <base_name>", file=sys.stderr)
        print("  base_name: e.g., manual-20260803-113501-20260803-113501", file=sys.stderr)
        sys.exit(1)

    base_name = sys.argv[1]
    # If a search_dir is provided (e.g., $OUTPUT_DIR from capture.sh), use it.
    # Otherwise fall back to deriving from base_name (for backward compat).
    output_dir = sys.argv[2] if len(sys.argv) > 2 else None
    if output_dir:
        search_dir = Path(output_dir)
    else:
        base_path = Path(base_name).parent if '/' in base_name else Path('.')
        search_dir = base_path
    base_stem = Path(base_name).name
    base_filename = base_stem

    # Find input files
    video_pts_final = search_dir / f"pts_{base_filename}.pts.final.pts"
    if not video_pts_final.exists():
        video_pts_final = search_dir / f"{base_filename}.pts.final.pts"
    if not video_pts_final.exists():
        print(f"Video .final.pts not found: {video_pts_final}", file=sys.stderr)
        sys.exit(1)

    video_h264 = search_dir / f"{base_filename}.p1.h264"
    if not video_h264.exists():
        video_h264 = search_dir / f"{base_filename}.h264"
    if not video_h264.exists():
        print(f"Video .h264 not found: {video_h264}", file=sys.stderr)
        sys.exit(1)

    # Source of truth: .h264.original (full pre-trim dump, created by capture.sh)
    video_h264_backup = video_h264.with_suffix(video_h264.suffix + '.original')
    if not video_h264_backup.exists():
        print(f"ERROR: {video_h264_backup} not found.", file=sys.stderr)
        print(f"  capture.sh must run `cp -p` before trim_segments.py.", file=sys.stderr)
        sys.exit(1)

    # Clean up stale .trim.tmp from a previous crash (atomic-write leftover)
    stale_tmp = str(video_h264) + ".trim.tmp"
    if os.path.exists(stale_tmp):
        try:
            os.remove(stale_tmp)
            print(f"  [video] removed stale temp file from previous crash: {stale_tmp}")
        except OSError as e:
            print(f"  WARNING: could not remove stale temp: {e}", file=sys.stderr)

    print(f"📹 trimming video: {video_h264}")
    print(f"   reading frames from: {video_h264_backup}")

    # Parse .final.pts and find segments
    rows = read_final_pts(video_pts_final)
    segments = split_segments_by_frame_no(rows)

    print(f"  detected {len(segments)} video segment(s):")
    for i, seg in enumerate(segments):
        first_pts = seg[0][1] / 1_000_000
        last_pts = seg[-1][1] / 1_000_000
        span = last_pts - first_pts
        marker = "  ← MAIN" if i == pick_main_segment(segments)[1] else ""
        print(f"    [{i}] {len(seg):5d} frames, dts={seg[0][2]}..{seg[-1][2]}, "
              f"pts={first_pts:.3f}s..{last_pts:.3f}s (span {span:.3f}s){marker}")

    main_seg, main_idx = pick_main_segment(segments)

    # main_seg 是 pts_finalize 按 PTS 升序排过的，所以 main_seg[0] 是 PTS 最小帧。
    # 但这里需要按 DTS（decoder order）输出，因为 H.264 bitstream 必须 DTS 顺序。
    # 1. 在 PTS-sorted main_seg 里找第一个 IDR
    # 2. 从该 IDR 起按 dts_order 数值升序输出（不是 PTS 顺序）

    # Step 1: find first keyframe in main_seg (r[5] is keyframe column from pts_finalize)
    first_kf_idx = None
    first_kf_dts = None
    for i, r in enumerate(main_seg):
        if r[5] == 1:  # keyframe=1 (IDR)
            first_kf_idx = i
            first_kf_dts = r[2]
            break

    if first_kf_idx is None:
        print(f"ERROR: main segment [{main_idx}] has no keyframe (IDR)", file=sys.stderr)
        sys.exit(1)

    # Step 2: 按 dts_order 数值升序，保留 dts >= first_kf_dts 的所有帧
    # （这是真正的 DTS 顺序，不是 PTS 顺序）
    main_dts_order = sorted(r[2] for r in main_seg if r[2] >= first_kf_dts)
    kept_dts = set(main_dts_order)
    print(f"  [video] keeping segment [{main_idx}] from first IDR "
          f"(dts={main_dts_order[0]}..{main_dts_order[-1]}, {len(main_dts_order)} frames)")

    # Read all frames from .original (the full pre-trim dump)
    FRAME_HDR_SIZE = 12  # frame_size_le(4) + pts_le(8)

    with open(video_h264_backup, 'rb') as f_in:
        magic = f_in.read(4)
        if magic != b'SDFV':
            print(f"ERROR: not SDFV format (magic={magic!r})", file=sys.stderr)
            sys.exit(1)
        f_in.read(4)  # version + reserved
        hdr_len_bytes = f_in.read(4)
        if len(hdr_len_bytes) < 4:
            print(f"ERROR: invalid header length", file=sys.stderr)
            sys.exit(1)
        header_len = struct.unpack('<I', hdr_len_bytes)[0]
        if header_len > 0:
            f_in.seek(header_len, 1)

        # First pass: read all frames into memory, indexed by dts_order
        frames_by_dts = {}
        dts_order = 0
        while True:
            hdr = f_in.read(FRAME_HDR_SIZE)
            if len(hdr) < FRAME_HDR_SIZE:
                break
            frame_size, pts = struct.unpack('<IQ', hdr)
            data = f_in.read(frame_size)
            if len(data) < frame_size:
                break
            dts_order += 1
            if dts_order in kept_dts:
                frames_by_dts[dts_order] = (frame_size, pts, data)

        # Second pass: write frames in DTS order (decoder order) to temp file,
        # then atomic rename. Crash mid-write → .h264 stays untouched.
        tmp_output = str(video_h264) + ".trim.tmp"
        with open(tmp_output, 'wb') as f_out:
            # Write header (must match input format)
            f_out.write(b'SDFV')
            f_out.write(struct.pack('<B3s', 1, b'\x00\x00\x00'))   # version=1, reserved=0
            f_out.write(struct.pack('<I', 0))                       # header_len=0

            kept_count = 0
            missing = 0
            # 按 DTS 顺序输出（不是 PTS）。H.264 bitstream 必须 DTS 顺序，
            # 否则 B 帧参考关系错乱 → 解码器花屏/报错
            for dts in main_dts_order:
                if dts in frames_by_dts:
                    frame_size, pts, data = frames_by_dts[dts]
                    f_out.write(struct.pack('<I', frame_size))
                    f_out.write(struct.pack('<Q', pts))
                    f_out.write(data)
                    kept_count += 1
                else:
                    missing += 1

        if missing > 0:
            print(f"  WARNING: {missing} frames in main segment had no matching dump frame",
                  file=sys.stderr)

    total_frames = dts_order
    dropped_count = total_frames - kept_count

    # Sanity-check temp output before atomic replace
    tmp_output_size = os.path.getsize(tmp_output)
    orig_size = os.path.getsize(video_h264_backup)
    if tmp_output_size == 0 or tmp_output_size > orig_size * 2:
        print(f"ERROR: trimmed output looks wrong (size={tmp_output_size}, "
              f"orig={orig_size})", file=sys.stderr)
        os.remove(tmp_output)
        sys.exit(1)

    # Atomic replace .h264 with verified trimmed version
    os.replace(tmp_output, str(video_h264))
    new_size = os.path.getsize(video_h264)

    print(f"  [video] kept {kept_count}/{total_frames} frames ({dropped_count} dropped)")
    print(f"  [video] written in DTS order (decoder order) from first IDR")
    print(f"  [video] {orig_size} -> {new_size} bytes")
    print(f"\n✅ trim done — {video_h264.name} is now main segment only")
    print(f"   original dump preserved as {video_h264_backup.name}")


if __name__ == '__main__':
    main()