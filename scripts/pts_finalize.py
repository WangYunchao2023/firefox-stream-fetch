#!/usr/bin/env python3
"""
pts_finalize.py — Post-process PTSDumpLogger output to user-spec format.

Input  (PTSDumpLogger 6-column):
  # frame_index  pts_us  duration_us  size  keyframe  offset
  1              0        66666         1649  1         48
  2              66666    66666         49    0         1697
  ...

Output (7-column, per user spec):
  # frame_No#  pts_us  dts_order  duration_us  size  keyframe
  1            0       1           66666         1649  1
  2            66666   2           66666         49    0
  ...

Transformations (in order):
  1. Drop offset column
  2. Rename frame_index -> dts_order (header label only)
  3. Reorder columns to: pts_us, dts_order, duration_us, size, keyframe
  4. Detect pts_us jumps > --jump-threshold-s (default 5.0s) in DTS (frame_index) order
  5. Split into segments at jump boundaries
  6. Sort each segment by pts_us ascending
  7. Add frame_No# column (per-segment numbering, restart at 1 per segment)

Note: Original input file is NOT overwritten; output is written to <input>.final.pts
by default so the raw dump is preserved for debugging / comparison.
"""
import sys
import os
import argparse

JUMP_THRESHOLD_S_DEFAULT = 5.0


def parse_input(path):
    """Parse PTSDumpLogger 6-column output.

    Returns list of dicts with keys:
        frame_index, pts_us, duration_us, size, keyframe, offset
    Skips blank lines and '#' comment / header lines.
    Skips rows with <6 columns (defensive: malformed lines).
    """
    rows = []
    with open(path, 'r') as f:
        for line in f:
            line = line.rstrip('\n').rstrip('\r')
            if not line or line.startswith('#'):
                continue
            parts = line.split('\t')
            if len(parts) < 6:
                # Skip malformed lines silently
                continue
            rows.append({
                'frame_index': int(parts[0]),
                'pts_us':      int(parts[1]),
                'duration_us': int(parts[2]),
                'size':        int(parts[3]),
                'keyframe':    int(parts[4]),
                'offset':      int(parts[5]),
            })
    return rows


def split_by_pts_jump(rows, threshold_us):
    """Detect pts_us jumps > threshold_us between consecutive rows (in DTS order).

    rows are expected to be sorted by frame_index (i.e. decoder order).
    A jump is defined as: abs(rows[i].pts_us - rows[i-1].pts_us) > threshold_us.
    BOTH forward and backward jumps trigger a split.

    Rationale: within a single video stream, pts_us only varies within ~1 frame
    interval (B-frame reordering, typically <200ms for 30fps). Large forward
    jumps indicate a stream forward skip (episode change, dump restart).
    Large backward jumps indicate a stream wraparound / PTS reset (firefox dump
    quirk where warmup-like PTS appears late in DTS — must be isolated into
    its own segment, not mixed with the main video frames).
    """
    if not rows:
        return []
    segments = [[rows[0]]]
    for r in rows[1:]:
        prev = segments[-1][-1]
        if abs(r['pts_us'] - prev['pts_us']) > threshold_us:
            segments.append([r])
        else:
            segments[-1].append(r)
    return segments


def main():
    parser = argparse.ArgumentParser(
        description='Finalize PTSDumpLogger .pts (drop offset, rename column, '
                    'segment by PTS jump, sort segments, add frame_No#).')
    parser.add_argument('input', help='Input .pts file (PTSDumpLogger 6-column format)')
    parser.add_argument('-o', '--output', default=None,
                        help='Output file (default: <input>.final.pts)')
    parser.add_argument('--jump-threshold-s', type=float,
                        default=JUMP_THRESHOLD_S_DEFAULT,
                        help=f'PTS jump threshold in seconds (default: {JUMP_THRESHOLD_S_DEFAULT})')
    args = parser.parse_args()

    # Default output path: <input>.final.pts (preserve original)
    if args.output is None:
        args.output = args.input + '.final.pts'

    rows = parse_input(args.input)
    if not rows:
        print(f"ERROR: no data rows in {args.input}", file=sys.stderr)
        sys.exit(1)

    # PTSDumpLogger writes in DTS (decoder) order — frame_index is monotonically
    # increasing. Sanity-check and log if not (shouldn't happen, but be defensive).
    for i in range(1, len(rows)):
        if rows[i]['frame_index'] < rows[i-1]['frame_index']:
            print(f"WARNING: frame_index not monotonic at row {i+1} "
                  f"({rows[i-1]['frame_index']} -> {rows[i]['frame_index']}); "
                  f"results may be wrong", file=sys.stderr)
            break

    # 1. Split into segments by pts_us jump (> threshold, in DTS order)
    threshold_us = int(args.jump_threshold_s * 1_000_000)
    segments = split_by_pts_jump(rows, threshold_us)
    print(f"split into {len(segments)} segment(s) by pts_us jump > "
          f"{args.jump_threshold_s}s", file=sys.stderr)
    for i, seg in enumerate(segments):
        seg_span_us = seg[-1]['pts_us'] - seg[0]['pts_us']
        print(f"  segment {i}: {len(seg):>5} frames, "
              f"pts_us={seg[0]['pts_us']}..{seg[-1]['pts_us']} us "
              f"(span={seg_span_us/1_000_000:.3f}s, "
              f"dts_order={seg[0]['frame_index']}..{seg[-1]['frame_index']})",
              file=sys.stderr)

    # 2. Sort each segment by pts_us ascending
    for seg in segments:
        seg.sort(key=lambda r: r['pts_us'])

    # 3. Write output (per-segment frame_No# restart at 1)
    total_frames = sum(len(s) for s in segments)
    with open(args.output, 'w') as f:
        f.write("# frame_No#\tpts_us\tdts_order\tduration_us\tsize\tkeyframe\n")
        for seg_idx, seg in enumerate(segments):
            for frame_no, r in enumerate(seg, start=1):
                f.write(f"{frame_no}\t{r['pts_us']}\t{r['frame_index']}\t"
                        f"{r['duration_us']}\t{r['size']}\t{r['keyframe']}\n")

    print(f"wrote {total_frames} frames across {len(segments)} segment(s) "
          f"-> {args.output}", file=sys.stderr)


if __name__ == '__main__':
    main()