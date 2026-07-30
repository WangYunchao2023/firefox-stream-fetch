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
import argparse

# 确保 user site-packages 在 sys.path（conda base 会设 PYTHONNOUSERSITE=1，导致 pip 安装的 av 找不到）
try:
    import site
    if hasattr(site, 'ENABLE_USER_SITE') and not site.ENABLE_USER_SITE:
        # 被禁用（如 conda base），手动加 user site-packages 路径
        site.ENABLE_USER_SITE = True
        site.addsitedir(site.getusersitepackages())
except Exception:
    pass

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


def mux_video(prefix, pts_file, raw_file, out_path, rebase_at_first_keyframe=False, first_keyframe_idx=-1, audio_duration_us=0):
    """Mux H.264/HEVC raw stream with per-frame PTS → mp4.

    audio_duration_us: if > 0, use this as the canonical playback duration
        (computed from AAC frame count). Video frame_duration = audio_duration / n_frames.
        This forces A/V sync and works even when firefox's per-frame PTS is broken.
    """
    pts_list = read_pts(pts_file)
    if not pts_list:
        print(f"ERROR: no PTS in {pts_file}", file=sys.stderr)
        return False

    # 检查 PTS 是否可信：span < n_frames/30 秒说明 PTS 过密（firefox MSE 的 mTime 不可信）
    # 优先用音频时长推算视频帧间隔（最准，audio as clock），否则用相邻 PTS 差值中位数
    n_frames = len(pts_list)
    span_us = max(pts_list) - min(pts_list) if pts_list else 0
    if n_frames > 100 and span_us < (n_frames * 1_000_000 // 30):
        if audio_duration_us > 0:
            # 以音频时长为权威时钟源：视频帧率 = n_frames / audio_duration
            frame_dur_us = audio_duration_us // n_frames
            pts_list = [int(i * frame_dur_us) for i in range(n_frames)]
            print(f"video: PTS span too short ({span_us/1_000_000:.3f}s for {n_frames} frames), "
                  f"using audio as clock ({audio_duration_us/1_000_000:.3f}s -> "
                  f"{1000000/frame_dur_us:.2f}fps)", file=sys.stderr)
        else:
            # 无音频时长参考时，退回到相邻 PTS 差值中位数（避开 chunk 边界跳变）
            deltas = []
            for i in range(1, len(pts_list)):
                d = pts_list[i] - pts_list[i-1]
                if 10000 < d < 200000:  # 5~200fps 之间才合理
                    deltas.append(d)
            if deltas:
                deltas.sort()
                frame_dur_us = deltas[len(deltas) // 2]  # 中位数
            else:
                frame_dur_us = 40000  # fallback 25fps
            pts_list = [int(i * frame_dur_us) for i in range(n_frames)]
            print(f"video: PTS span too short ({span_us/1_000_000:.3f}s for {n_frames} frames), "
                  f"recomputing with {1000000/frame_dur_us:.2f}fps (median delta from {len(deltas)} valid samples)",
                  file=sys.stderr)

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
    """Mux ADTS stream with per-frame PTS → m4a.

    Returns the canonical audio duration in microseconds (n_frames * 1024 / sample_rate),
    so caller can use it as the clock source for video mux.
    """
    pts_list = read_pts(pts_file)
    if not pts_list:
        print(f"ERROR: no PTS in {pts_file}", file=sys.stderr)
        return False

    input_container = av.open(raw_file, format='aac')
    in_stream = input_container.streams.audio[0]

    # 检查 PTS 是否可信：AAC 帧间间隔固定 (1024/sample_rate 秒)
    # 如果 span 远小于 n_frames * frame_duration，PTS 不可信，重算
    n_a_frames = len(pts_list)
    span_us = max(pts_list) - min(pts_list) if pts_list else 0
    sample_rate = in_stream.codec_context.sample_rate or 44100
    aac_frame_dur_us = 1_000_000 * 1024 // sample_rate  # 1024 samples/frame
    expected_min_us = n_a_frames * aac_frame_dur_us // 4  # 至少 1/4 样本间隔才合理
    if n_a_frames > 100 and span_us < expected_min_us:
        pts_list = [i * aac_frame_dur_us for i in range(n_a_frames)]
        print(f"audio: PTS span too short ({span_us/1_000_000:.3f}s for {n_a_frames} frames), "
              f"recomputing with {aac_frame_dur_us}us/frame (sr={sample_rate})", file=sys.stderr)

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
    parser.add_argument('--audio-duration-us', type=int, default=0,
                        help='Canonical audio duration in microseconds (used as clock source for video mux)')
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
                       first_keyframe_idx=args.first_keyframe_idx,
                       audio_duration_us=args.audio_duration_us)
    else:
        ok = mux_audio(args.prefix, pts_file, raw_file, out_path)

    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()