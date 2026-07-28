#!/usr/bin/env python3
"""
Mux raw stream + per-frame PTS into mp4/m4a with PyAV.

Input files (from sdfv_extract.py):
  - <prefix>.raw:  concatenated frame data (NAL or ADTS)
  - <prefix>.pts:  one PTS per line (microseconds)

Output:
  - <prefix>.mp4  (video)
  - <prefix>.m4a  (audio)

Usage:
  mux_with_pts.py <prefix> <kind> [--rebase-at-first-keyframe] [--first-keyframe-idx N]
    kind = 'video' or 'audio'
"""
import sys
import os
import av
import argparse


def read_pts(pts_file):
    """Read .pts file, return list of PTS in microseconds."""
    pts_list = []
    with open(pts_file, 'r') as f:
        for line in f:
            line = line.strip()
            if line:
                pts_list.append(int(line))
    return pts_list


def mux_video(prefix, pts_file, raw_file, out_path, rebase_at_first_keyframe=False, first_keyframe_idx=-1):
    """Mux H.264/HEVC raw stream with per-frame PTS → mp4."""
    pts_list = read_pts(pts_file)
    if not pts_list:
        print(f"ERROR: no PTS in {pts_file}", file=sys.stderr)
        return False

    # Rebase PTS if requested: shift so first keyframe PTS = 0
    if rebase_at_first_keyframe and first_keyframe_idx >= 0 and first_keyframe_idx < len(pts_list):
        base_pts = pts_list[first_keyframe_idx]
        pts_list = [pts - base_pts for pts in pts_list]
        # Drop frames before first keyframe
        pts_list = pts_list[first_keyframe_idx:]
        print(f"video: rebased PTS, dropped {first_keyframe_idx} pre-keyframe frames, base_pts={base_pts}us", file=sys.stderr)

    # Open input raw stream (auto-detect H.264/HEVC)
    input_container = av.open(raw_file, mode='r')
    in_stream = input_container.streams.video[0]

    # Create output mp4
    output = av.open(out_path, mode='w', format='mp4')
    out_stream = output.add_stream_from_template(in_stream)
    out_stream.time_base = av.time_base  # 1/1000000

    # Need SPS/PPS as extradata for mp4 container
    if in_stream.codec_context.extradata:
        out_stream.codec_context.extradata = in_stream.codec_context.extradata

    pts_idx = 0
    for packet in input_container.demux(in_stream):
        if pts_idx >= len(pts_list):
            break
        if packet.size == 0:
            continue
        # Set PTS from our .pts file (microseconds)
        packet.pts = pts_list[pts_idx]
        packet.dts = pts_list[pts_idx]
        packet.stream = out_stream
        output.mux(packet)
        pts_idx += 1

    output.close()
    input_container.close()

    duration_s = (pts_list[min(pts_idx, len(pts_list)-1)] - pts_list[0]) / 1_000_000
    print(f"video: muxed {pts_idx} frames, span={duration_s:.3f}s -> {out_path}",
          file=sys.stderr)
    return True


def mux_audio(prefix, pts_file, raw_file, out_path):
    """Mux ADTS stream with per-frame PTS → m4a."""
    pts_list = read_pts(pts_file)
    if not pts_list:
        print(f"ERROR: no PTS in {pts_file}", file=sys.stderr)
        return False

    input_container = av.open(raw_file, format='aac')
    in_stream = input_container.streams.audio[0]

    output = av.open(out_path, mode='w', format='mp4')
    out_stream = output.add_stream_from_template(in_stream)
    out_stream.time_base = av.time_base  # 1/1000000

    pts_idx = 0
    for packet in input_container.demux(in_stream):
        if pts_idx >= len(pts_list):
            break
        if packet.size == 0:
            continue
        packet.pts = pts_list[pts_idx]
        packet.dts = pts_list[pts_idx]
        packet.stream = out_stream
        output.mux(packet)
        pts_idx += 1

    output.close()
    input_container.close()

    duration_s = (pts_list[min(pts_idx, len(pts_list)-1)] - pts_list[0]) / 1_000_000
    print(f"audio: muxed {pts_idx} frames, span={duration_s:.3f}s -> {out_path}",
          file=sys.stderr)
    return True


def main():
    parser = argparse.ArgumentParser(description='Mux raw stream + PTS to mp4/m4a')
    parser.add_argument('prefix', help='Prefix for .raw/.pts files')
    parser.add_argument('kind', choices=['video', 'audio'], help='video or audio')
    parser.add_argument('--rebase-at-first-keyframe', action='store_true',
                        help='Shift PTS so first keyframe = 0, drop frames before it')
    parser.add_argument('--first-keyframe-idx', type=int, default=-1,
                        help='Index of first keyframe (from sdfv_extract.detect_first_keyframe_index)')
    args = parser.parse_args()

    pts_file = f"{args.prefix}.pts"
    raw_file = f"{args.prefix}.raw"
    out_path = f"{args.prefix}.{'mp4' if args.kind == 'video' else 'm4a'}"

    if not os.path.exists(pts_file):
        print(f"ERROR: {pts_file} not found", file=sys.stderr)
        sys.exit(1)
    if not os.path.exists(raw_file):
        print(f"ERROR: {raw_file} not found", file=sys.stderr)
        sys.exit(1)

    if args.kind == 'video':
        ok = mux_video(args.prefix, pts_file, raw_file, out_path,
                       rebase_at_first_keyframe=args.rebase_at_first_keyframe,
                       first_keyframe_idx=args.first_keyframe_idx)
    else:
        ok = mux_audio(args.prefix, pts_file, raw_file, out_path)

    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()