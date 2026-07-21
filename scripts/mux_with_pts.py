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
  mux_with_pts.py <prefix> <kind>
    kind = 'video' or 'audio'
"""
import sys
import os
import av


def read_pts(pts_file):
    """Read .pts file, return list of PTS in microseconds."""
    pts_list = []
    with open(pts_file, 'r') as f:
        for line in f:
            line = line.strip()
            if line:
                pts_list.append(int(line))
    return pts_list


def mux_video(prefix, pts_file, raw_file, out_path):
    """Mux H.264/HEVC raw stream with per-frame PTS → mp4."""
    pts_list = read_pts(pts_file)
    if not pts_list:
        print(f"ERROR: no PTS in {pts_file}", file=sys.stderr)
        return False

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
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <prefix> <kind>", file=sys.stderr)
        print(f"  kind = 'video' or 'audio'", file=sys.stderr)
        sys.exit(1)

    prefix = sys.argv[1]
    kind = sys.argv[2]

    pts_file = f"{prefix}.pts"
    raw_file = f"{prefix}.raw"
    out_path = f"{prefix}.{'mp4' if kind == 'video' else 'm4a'}"

    if not os.path.exists(pts_file):
        print(f"ERROR: {pts_file} not found", file=sys.stderr)
        sys.exit(1)
    if not os.path.exists(raw_file):
        print(f"ERROR: {raw_file} not found", file=sys.stderr)
        sys.exit(1)

    if kind == 'video':
        ok = mux_video(prefix, pts_file, raw_file, out_path)
    elif kind == 'audio':
        ok = mux_audio(prefix, pts_file, raw_file, out_path)
    else:
        print(f"ERROR: unknown kind '{kind}'", file=sys.stderr)
        sys.exit(1)

    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()