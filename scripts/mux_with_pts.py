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
import struct
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


def pts_jump_drop_offset_from_dump(sdfv_path, drop_index, threshold_us=500_000):
    """Find byte offset of frame [drop_index] in SDFV dump file.

    Reads the original SDFV dump (which has per-frame size fields) and returns
    the cumulative byte offset at which frame [drop_index] begins.
    Returns -1 on error.
    """
    FRAME_HDR_SIZE = 12  # frame_size_le(4) + pts_le(8)
    with open(sdfv_path, 'rb') as f:
        magic = f.read(4)
        if magic == b'SDFV':
            f.read(4)  # version + reserved
            hdr_len_bytes = f.read(4)
            if len(hdr_len_bytes) < 4:
                return -1
            header_len = struct.unpack('<I', hdr_len_bytes)[0]
            if header_len > 0:
                f.seek(header_len, 1)
        elif magic == b'SDFA':
            f.read(4)  # version + reserved
        else:
            return -1

        offset = 0
        for i in range(drop_index):
            hdr = f.read(FRAME_HDR_SIZE)
            if len(hdr) < FRAME_HDR_SIZE:
                return -1
            frame_size, _pts = struct.unpack('<IQ', hdr)
            offset += FRAME_HDR_SIZE + frame_size
            f.seek(frame_size, 1)
        return offset


def find_pts_jump_drop(raw_file, pts_list, dump_path=None, threshold_us=500_000):
    """Scan pts_list for backward PTS jumps and compute byte offset.

    Returns (drop_index, drop_offset_in_raw) where:
      - drop_index: first frame whose PTS is significantly lower than previous
      - drop_offset_in_raw: byte offset in .raw file BEFORE the drop frame
        (sum of sizes of all frames before drop_index)

    If dump_path is provided, uses SDFV per-frame size fields for precision.
    Otherwise scans raw file for H.264/HEVC start codes (less reliable).

    A backward jump means: pts[i] < pts[i-1] AND the drop is large
    (>= threshold_us, default 0.5s to avoid noise from normal PTS jitter).
    
    Note: instead of stopping at the first backward jump (which may be MSE buffer
    jitter), we scan the entire list and pick the largest backward jump. This
    ensures a massive next_episode PTS reset (~300s+) beats smaller jitters (<5s).
    """
    if len(pts_list) < 2:
        return -1, 0

    drop_index = -1
    max_drop_us = 0
    for i in range(1, len(pts_list)):
        prev_pts = pts_list[i - 1]
        cur_pts = pts_list[i]
        # 向后跳变：当前 PTS < 前一帧 且 落差超过阈值
        if cur_pts < prev_pts and (prev_pts - cur_pts) >= threshold_us:
            jump_us = prev_pts - cur_pts
            if jump_us > max_drop_us:
                max_drop_us = jump_us
                drop_index = i

    if drop_index < 0:
        return -1, 0

    # 优先用原始 SDFV dump 文件（有 per-frame size 字段）精确计算偏移
    if dump_path and os.path.isfile(dump_path):
        offset = pts_jump_drop_offset_from_dump(dump_path, drop_index)
        if offset >= 0:
            return drop_index, offset

    # Fallback: 从 .raw 扫描 NAL start code（不精确，仅当 dump 丢失时）
    FRAME_HDR_SIZE = 12
    with open(raw_file, 'rb') as f:
        magic = f.read(4)
        skip = 0
        if magic == b'SDFV':
            f.read(4)  # version + reserved
            hdr_len_bytes = f.read(4)
            if len(hdr_len_bytes) < 4:
                return -1, 0
            header_len = struct.unpack('<I', hdr_len_bytes)[0]
            if header_len > 0:
                f.seek(header_len, 1)  # skip SPS/PPS header
                skip += header_len
        elif magic == b'SDFA':
            print(f"video: PTS 跳变检测：音频模式不支持 .raw 帧截断",
                  file=sys.stderr)
            return -1, 0
        else:
            return -1, 0  # unknown format

        # 跳过前 drop_index 帧，累积字节偏移
        offset = 0
        frames_scanned = 0
        while frames_scanned < drop_index:
            chunk = f.read(65536)
            if not chunk:
                break
            sc_pos = chunk.find(b'\x00\x00\x01')
            if sc_pos < 0:
                sc_pos = chunk.find(b'\x00\x00\x00')
            if sc_pos >= 0:
                # start code 标志着新 NALU 起始 → 当前 NALU 结束
                offset += sc_pos
                frames_scanned += 1
                # 继续扫描下一个 NALU（可能在同批次剩余数据中）
            else:
                # 当前批次无 start code，整个批次属于同一帧
                offset += len(chunk)

    return drop_index, offset


def mux_video(prefix, pts_file, raw_file, out_path, dump_file=None,
              rebase_at_first_keyframe=False, first_keyframe_idx=-1, audio_duration_us=0):
    """Mux H.264/HEVC raw stream with per-frame PTS → mp4.

    dump_file: original SDFV dump path (used for precise byte offset calc).
    audio_duration_us: if > 0, use this as the canonical playback duration
        (computed from AAC frame count). Video frame_duration = audio_duration / n_frames.
        This forces A/V sync and works even when firefox's per-frame PTS is broken.
    """
    pts_list = read_pts(pts_file)
    if not pts_list:
        print(f"ERROR: no PTS in {pts_file}", file=sys.stderr)
        return False

    # PTS 跳变截断：检测并截掉 next_episode 残留帧
    # 必须在 PTS 重算之前执行——否则 audio-clock 会把 PTS 线性化，掩盖跳变
    drop_idx, drop_offset = find_pts_jump_drop(raw_file, pts_list,
                                                dump_path=dump_file)
    if drop_idx > 0 and drop_offset > 0:
        print(f"video: PTS 跳变检测 (drop@frame={drop_idx}, offset={drop_offset}B)，截断...",
              file=sys.stderr)
        with open(raw_file, 'r+b') as f:
            f.truncate(drop_offset)
        pts_list = pts_list[:drop_idx]
        print(f"video: 截断后剩余 {len(pts_list)} 帧",
              file=sys.stderr)

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

    # === Build monotonic DTS list ===
    # H.264 有 B 帧，dump 顺序（DTS）≠ 显示顺序（PTS），所以 pts_list 不单调。
    # mp4 muxer 要求 DTS 单调。原代码把 DTS 也设成 pts_list 导致 PyAV EINVAL。
    # 这里单独算一组单调 DTS（DTS[i] = i * avg_frame_dur），DTS 与 PTS 各自的语义
    # 独立：mp4 stts 用 DTS（解码序），ctts 用 PTS-DTS（显示偏移），都允许。
    n_frames = len(pts_list)
    if n_frames > 1:
        span_us_now = max(pts_list) - min(pts_list)
        avg_frame_dur_us = max(1, span_us_now // (n_frames - 1))
    else:
        avg_frame_dur_us = 40000  # fallback 25fps
    dts_list = [int(i * avg_frame_dur_us) for i in range(n_frames)]

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
        if packet.size == 0:
            continue
        # PTS = 原始（显示序，可能不单调 — B 帧重排产物）
        packet.pts = pts_list[pts_idx]
        # DTS = 单调（解码序）— mp4 muxer 硬要求
        packet.dts = dts_list[pts_idx]
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