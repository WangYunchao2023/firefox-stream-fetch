#!/usr/bin/env python3
"""
Mux raw stream + per-frame PTS into mp4/m4a with PyAV.

Input files (from sdfv_extract.py):
  - <prefix>.raw:  concatenated frame data (NAL or ADTS)
  - <prefix>.pts:  one PTS per line (microseconds)

Output:
  - <prefix>.mp4  (video, when kind=video)
  - <prefix>.m4a  (audio, when kind=audio)

v3.4 新增:
  --rebase-at-first-keyframe  (video only, opt-in)
     在 mp4 输出时, 找到第一个 IDR/keyframe sample, 把它的 PTS 当作 0,
     所有 sample 的 PTS 减去这个 anchor 后写入 mp4 容器.
     这个选项让 StreamDumper 不再需要在 firefox 端做"预热门控"——
     启动残留的 junk 帧在 mux 时被一刀切除, 首个真关键帧 = t=0.

Usage:
  mux_with_pts.py <prefix> <kind> [--rebase-at-first-keyframe]
"""
import sys
import os
import subprocess
import av

# 引用同目录 sdfv_extract 提供的数据
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sdfv_extract


def read_pts(pts_file):
    """Read .pts file, return list of PTS in microseconds."""
    pts_list = []
    with open(pts_file, 'r') as f:
        for line in f:
            line = line.strip()
            if line:
                pts_list.append(int(line))
    return pts_list


def _ffprobe_timebase_fps(raw_file):
    """用 ffprobe 探测 raw 流 → (avg_frame_rate as fraction, e.g. (30000, 1001))."""
    try:
        out = subprocess.check_output(
            ["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=avg_frame_rate,r_frame_rate",
             "-of", "default=nw=1", raw_file],
            stderr=subprocess.DEVNULL, timeout=10
        ).decode().strip()
        for line in out.splitlines():
            k, _, v = line.partition("=")
            if k == "avg_frame_rate" and v and "/" in v:
                num, _, den = v.partition("/")
                return int(num), int(den) if int(den) else 1
    except (subprocess.CalledProcessError, FileNotFoundError, ValueError):
        pass
    return None


def mux_video(prefix, pts_file, raw_file, out_path, rebase_keyframe=False):
    """Mux H.264/HEVC raw stream with per-frame PTS → mp4.

    rebase_keyframe=True: find first IDR/keyframe sample, use its PTS as the
    anchor (t=0); all subsequent sample PTS -= anchor before mux.
    """
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

    # 决定 anchor PTS
    anchor_pts_us = 0
    anchor_idx = 0
    if rebase_keyframe:
        # 我们需要直接读 dump 找首 IDR sample 的 pts。
        # 这里调 sdfv_extract.detect_first_keyframe_index(dump_file)。
        # dump_file = prefix + ".sdfv" (StreamDumper 写出) 或 .h264/.av1 (从 MOZ_STREAM_DUMP_PATH 得)
        # 探测常见后缀:
        dump_path = None
        for ext in (".sdfv", ".h264", ".av1", ".h265"):
            p = prefix + ext
            if os.path.exists(p):
                dump_path = p
                break
        if dump_path is None:
            print(f"ERROR: --rebase-at-first-keyframe 找不到 dump 文件 ({prefix}.{{sdfv,h264,av1,h265}})",
                  file=sys.stderr)
            return False
        anchor_idx, anchor_pts_us = sdfv_extract.detect_first_keyframe_index(dump_path)
        if anchor_pts_us is None:
            print(f"WARN: --rebase-at-first-keyframe 未找到 IDR sample, 跳过 rebase",
                  file=sys.stderr)
            anchor_pts_us = 0
            anchor_idx = 0
        else:
            print(f"   rebase: 首 IDR 是 idx={anchor_idx} pts={anchor_pts_us}us → t=0",
                  file=sys.stderr)

    pts_idx = 0
    n_written = 0
    for packet in input_container.demux(in_stream):
        if pts_idx >= len(pts_list):
            break
        if packet.size == 0:
            continue
        # 按 anchor_idx 之前的样本丢弃 (junk frames)
        if rebase_keyframe and pts_idx < anchor_idx:
            pts_idx += 1
            continue
        # Set PTS from our .pts file (microseconds), rebase by anchor
        raw_pts = pts_list[pts_idx]
        rebased_pts = max(0, raw_pts - anchor_pts_us)
        packet.pts = rebased_pts
        packet.dts = rebased_pts
        packet.stream = out_stream
        output.mux(packet)
        pts_idx += 1
        n_written += 1

    output.close()
    input_container.close()

    if len(pts_list) > 0:
        end_pts = pts_list[-1]
        duration_s = (end_pts - (pts_list[0] if not rebase_keyframe else anchor_pts_us)) / 1_000_000
    else:
        duration_s = 0
    rebase_str = f" rebased@idx{anchor_idx}" if rebase_keyframe else ""
    print(f"video: muxed {n_written} frames{rebase_str}, span={duration_s:.3f}s -> {out_path}",
          file=sys.stderr)
    return True


def mux_audio(prefix, pts_file, raw_file, out_path, rebase_anchor_pts_us=0):
    """Mux ADTS stream with per-frame PTS → m4a. (rebase optional, 由 video 端 anchor 传过来)"""
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
    n_written = 0
    for packet in input_container.demux(in_stream):
        if pts_idx >= len(pts_list):
            break
        if packet.size == 0:
            continue
        raw_pts = pts_list[pts_idx]
        rebased_pts = max(0, raw_pts - rebase_anchor_pts_us)
        packet.pts = rebased_pts
        packet.dts = rebased_pts
        packet.stream = out_stream
        output.mux(packet)
        pts_idx += 1
        n_written += 1

    output.close()
    input_container.close()

    duration_s = (pts_list[-1] - rebase_anchor_pts_us) / 1_000_000 if pts_list else 0
    rebase_str = f" rebased@{rebase_anchor_pts_us}us" if rebase_anchor_pts_us else ""
    print(f"audio: muxed {n_written} frames{rebase_str}, span={duration_s:.3f}s -> {out_path}",
          file=sys.stderr)
    return True


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <prefix> <kind> [--rebase-at-first-keyframe]", file=sys.stderr)
        print(f"  kind = 'video' or 'audio'", file=sys.stderr)
        sys.exit(1)

    prefix = sys.argv[1]
    kind = sys.argv[2]
    rebase_keyframe = "--rebase-at-first-keyframe" in sys.argv[3:]

    pts_file = f"{prefix}.pts"
    raw_file = f"{prefix}.raw"
    out_path = f"{prefix}.{'mp4' if kind == 'video' else 'm4a'}"

    if not os.path.exists(pts_file):
        print(f"ERROR: {pts_file} not found", file=sys.stderr)
        sys.exit(1)
    if not os.path.exists(raw_file):
        print(f"ERROR: {raw_file} not found", file=sys.stderr)
        sys.exit(1)

    # video rebase 时, 同步告诉 audio 端 anchor
    audio_anchor_pts = 0
    if rebase_keyframe and kind == "video":
        # 找 dump file 以读 IDR PTS
        dump_path = None
        for ext in (".sdfv", ".h264", ".av1", ".h265"):
            p = prefix + ext
            if os.path.exists(p):
                dump_path = p
                break
        if dump_path:
            _idx, audio_anchor_pts = sdfv_extract.detect_first_keyframe_index(dump_path) or (None, 0)

    ok = False
    if kind == "video":
        ok = mux_video(prefix, pts_file, raw_file, out_path,
                       rebase_keyframe=rebase_keyframe)
    elif kind == "audio":
        ok = mux_audio(prefix, pts_file, raw_file, out_path,
                       rebase_anchor_pts_us=audio_anchor_pts)
    else:
        print(f"ERROR: unknown kind '{kind}'", file=sys.stderr)
        sys.exit(1)

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
