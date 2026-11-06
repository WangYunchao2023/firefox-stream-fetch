#!/usr/bin/env python3
"""
Trim SDFV dump file by keeping only the main segment.

Prerequisite: caller must ensure ${base}.h264.original exists and contains the
FULL pre-trim dump. capture.sh handles this via `cp -p` before invoking this
script.

Workflow:
  1. Read .pts.final.pts to find main segment boundaries
  2. Read ALL frames from .h264.original into memory
  3. Find first IDR in main segment (必须从 IDR 开始,否则丢 SPS/PPS + 参考帧 → 花屏)
  4. Write frames from first IDR onwards in DTS order (decoder order) to
     temp file, then atomic rename → .h264
     注意:必须 DTS 顺序输出,不是 PTS 顺序。H.264 bitstream 解码依赖 DTS,
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


def _find_audio_pts_file(search_dir, base_filename):
    """Find raw audio .pts file (PTSDumpLogger 6-col output, NOT .pts.final.pts).

    firefox SplitPaths() inserts `_audio` before the last `.pts` extension:
      video "pts_<base>.pts"  →  audio "pts_<base>_audio.pts"
    base_filename 可能含 `.p1`（monitor 滚动 dump 后），但 PTS 文件名不含 .p1
    （PTS_FILE env var 在 monitor 滚动前已设置）。所以要尝试多种组合。
    """
    base_no_p1 = base_filename[:-3] if base_filename.endswith('.p1') else base_filename
    candidates = [
        search_dir / f"pts_{base_no_p1}_audio.pts",
        search_dir / f"pts_{base_filename}_audio.pts",
        search_dir / f"{base_no_p1}_audio.pts",
        search_dir / f"{base_filename}_audio.pts",
    ]
    for c in candidates:
        if c.exists():
            return c
    return None


def _detect_audio_segments_from_pts(audio_pts_path, threshold_us=5_000_000):
    """从 raw audio .pts（PTSDumpLogger 6-col）按 >5s PTS 跳变切段。

    AAC 无 B 帧重排，dump 顺序 = PTS 顺序，pts_us 在段内单调递增。
    >5s 跳变 = 段边界（多集切换 / dump 重启 / 冷启动产生的 PTS 回绕或跳变）。

    Returns: list of dicts:
      {'start_idx', 'end_idx', 'first_pts', 'last_pts', 'frame_count'}
    """
    rows = []
    with open(audio_pts_path) as f:
        for line in f:
            line = line.rstrip('\n').rstrip('\r')
            if not line or line.startswith('#'):
                continue
            parts = line.split('\t')
            if len(parts) < 2:
                continue
            try:
                rows.append((int(parts[0]), int(parts[1])))
            except ValueError:
                continue

    if not rows:
        return []

    segments = []
    seg_start = 0
    for i in range(1, len(rows)):
        if abs(rows[i][1] - rows[i - 1][1]) > threshold_us:
            segments.append((seg_start, i - 1))
            seg_start = i
    segments.append((seg_start, len(rows) - 1))

    return [
        {
            'start_idx': s,
            'end_idx': e,
            'first_pts': rows[s][1],
            'last_pts': rows[e][1],
            'frame_count': e - s + 1,
        }
        for s, e in segments
    ]


def trim_audio(audio_path, audio_backup_path,
               video_first_kept_pts, video_last_kept_pts,
               audio_first_idx, audio_last_idx):
    """Trim SDFA audio dump to main segment, intersect with video main.

    SDFA format (8-byte header, NO header_len field):
      magic(4='SDFA') + version(1)+reserved(3) + [frame_size(4) + pts(8) + data(N)]*

    双约束:
      (1) dump order (frame_index) ∈ [audio_first_idx, audio_last_idx]
          = audio 主段在 SDFA dump 文件中的帧范围（firefox 重启会"重置"audio PTS，
          数值上可能落在主段范围内；dump order 才是真实时序的可靠标识）
      (2) pts ∈ [video_first_kept_pts, video_last_kept_pts]
          = 进一步限定不超出 video main 时间范围（处理 audio 起点/终点越出 video）

    Robustness:
      - audio_backup 不存在 → INFO 跳过,return None
      - magic != SDFA → 跳过(不挡 video pass)
      - 双约束下空集 → 跳过,保留 .aac 原样
      - 输出 sanity check(空 / >2× orig)→ 删 tmp,不替换
    """
    if not audio_backup_path.exists():
        print(f"  [audio] ⏭️  {audio_backup_path.name} 不存在,跳过 audio trim")
        return None

    print(f"\n🎵 trimming audio: {audio_path.name}")
    print(f"   reading frames from: {audio_backup_path.name}")
    print(f"   main audio frame_index: [{audio_first_idx}, {audio_last_idx}]")
    print(f"   video main PTS range:   [{video_first_kept_pts}, {video_last_kept_pts}] us")
    print(f"   keeping frames in dump-order ∩ video PTS")

    # Clean up stale .trim.tmp from a previous crash (atomic-write leftover)
    stale_tmp = str(audio_path) + ".trim.tmp"
    if os.path.exists(stale_tmp):
        try:
            os.remove(stale_tmp)
            print(f"  [audio] removed stale temp file from previous crash: {stale_tmp}")
        except OSError as e:
            print(f"  WARNING: could not remove stale audio temp: {e}", file=sys.stderr)

    FRAME_HDR_SIZE = 12
    total_frames = 0
    kept_frames = []

    with open(audio_backup_path, 'rb') as f_in:
        magic = f_in.read(4)
        if magic != b'SDFA':
            print(f"  [audio] ERROR: not SDFA format (magic={magic!r}),跳过 audio trim",
                  file=sys.stderr)
            return None
        version_bytes = f_in.read(4)
        if len(version_bytes) < 4:
            print(f"  [audio] ERROR: invalid audio header (len<4),跳过 audio trim",
                  file=sys.stderr)
            return None
        version = version_bytes[0]
        if version != 1:
            print(f"  [audio] ERROR: unsupported audio version {version},跳过 audio trim",
                  file=sys.stderr)
            return None

        while True:
            hdr = f_in.read(FRAME_HDR_SIZE)
            if len(hdr) < FRAME_HDR_SIZE:
                break
            frame_size, pts = struct.unpack('<IQ', hdr)
            data = f_in.read(frame_size)
            if len(data) < frame_size:
                break
            total_frames += 1
            in_audio_main = audio_first_idx <= total_frames <= audio_last_idx
            in_video_main = video_first_kept_pts <= pts <= video_last_kept_pts
            if in_audio_main and in_video_main:
                kept_frames.append((frame_size, pts, data))

    if total_frames == 0:
        print(f"  [audio] ⏭️  audio dump 无可读帧（空文件？），跳过 audio trim")
        return None

    dropped_count = total_frames - len(kept_frames)

    if not kept_frames:
        print(f"  [audio] ⚠️  双约束(dump-order ∩ video PTS)下没有任何 audio 帧被保留")
        print(f"           audio 时钟与 video 严重不匹配,保留 .aac 原样不裁")
        return None

    # Atomic write: write to .trim.tmp, sanity-check, then os.replace
    tmp_output = str(audio_path) + ".trim.tmp"

    # === PTS 重定基 ===
    # audio 每一帧 PTS 减 video_first_kept_pts（如 -19.727s）：
    #   原 audio 首帧 PTS 21.943s - 19.727s = 2.216s
    # 跟 video pass 同步减同一个值，保留两者 dump 起点之差 (= 2.216s, firefox dump 中
    # audio decoder 比 video decoder 晚启动造成的偏差)。mux 后 mp4 里 video 从 0 起、
    # audio 从 2.216s 起，同 mp4 时刻两轨同一流时间 → A/V 同步。
    audio_pts_shift = -video_first_kept_pts

    with open(tmp_output, 'wb') as f_out:
        f_out.write(b'SDFA')
        f_out.write(struct.pack('<B3s', 1, b'\x00\x00\x00'))

        for frame_size, pts, data in kept_frames:
            f_out.write(struct.pack('<I', frame_size))
            f_out.write(struct.pack('<Q', pts + audio_pts_shift))
            f_out.write(data)

    tmp_output_size = os.path.getsize(tmp_output)
    orig_size = os.path.getsize(audio_backup_path)

    if tmp_output_size == 0:
        print(f"  [audio] ERROR: trimmed output is empty,跳过 audio trim",
              file=sys.stderr)
        try:
            os.remove(tmp_output)
        except OSError:
            pass
        return None

    if tmp_output_size > orig_size * 2:
        print(f"  [audio] ERROR: trimmed output too large "
              f"({tmp_output_size} > 2×{orig_size}),跳过 audio trim",
              file=sys.stderr)
        try:
            os.remove(tmp_output)
        except OSError:
            pass
        return None

    # Atomic replace .aac with verified trimmed version
    os.replace(tmp_output, str(audio_path))
    new_size = os.path.getsize(audio_path)

    print(f"  [audio] kept {len(kept_frames)}/{total_frames} frames ({dropped_count} dropped)")
    print(f"  [audio] PTS range: [{kept_frames[0][1]}, {kept_frames[-1][1]}] us")
    print(f"  [audio] {orig_size} -> {new_size} bytes")
    print(f"  ✅ audio trim done — {audio_path.name} now matches video main segment")
    return True


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

    # main_seg 是 pts_finalize 按 PTS 升序排过的,所以 main_seg[0] 是 PTS 最小帧。
    # 但这里需要按 DTS(decoder order)输出,因为 H.264 bitstream 必须 DTS 顺序。
    # 1. 在 PTS-sorted main_seg 里找第一个 IDR
    # 2. 从该 IDR 起按 dts_order 数值升序输出(不是 PTS 顺序)

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

    # Step 2: 按 dts_order 数值升序,保留 dts >= first_kf_dts 的所有帧
    # (这是真正的 DTS 顺序,不是 PTS 顺序)
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

            # === PTS 重定基 ===
            # 把 video 每一帧 PTS 减 video_first_kept_pts → dump 里 video 首帧=0。
            # audio 那边也减同一个值（video_first_kept_pts）→ audio 首帧=audio_first-video_first
            # （保留两者 dump 起点之差，反映 firefox dump 本身 audio 晚启动的偏移）。
            # mux 之后 mp4 里 video 从 0 起、audio 从 2.216s 起，同 mp4 时刻两轨是同一流时间
            # → A/V 同步。
            video_pts_shift = -frames_by_dts[main_dts_order[0]][1]  # = -video_first_kept_pts

            kept_count = 0
            missing = 0
            # 按 DTS 顺序输出(不是 PTS)。H.264 bitstream 必须 DTS 顺序,
            # 否则 B 帧参考关系错乱 → 解码器花屏/报错
            for dts in main_dts_order:
                if dts in frames_by_dts:
                    frame_size, pts, data = frames_by_dts[dts]
                    f_out.write(struct.pack('<I', frame_size))
                    f_out.write(struct.pack('<Q', pts + video_pts_shift))
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
    print(f"\n✅ trim done - {video_h264.name} is now main segment only")
    print(f"   original dump preserved as {video_h264_backup.name}")

    # === Audio pass (v4.3.5): mirror video PTS rebase, read raw audio .pts ===
    # AAC 无 B 帧重排，dump 顺序 = PTS 顺序，不需要 pts_finalize 重排。直接从 raw .pts 查 >5s
    # PTS 跳变拿到所有段边界，选最长段作为 main audio segment，用双重约束（dump-order ∩
    # video PTS）选出真正同步的帧。
    # 输出 PTS 同步减 video_first_kept_pts → audio 首帧 PTS = audio_first - video_first
    # （保留 firefox dump 中 audio 晚 video 启动的偏差 ≈ 2.216s）。mux 后 mp4 里 video 从 0
    # 起、audio 从 2.216s 起，同 mp4 时刻两轨同一流时间 → A/V 同步。
    video_first_kept_pts = min(frames_by_dts[d][1] for d in main_dts_order if d in frames_by_dts)
    video_last_kept_pts = max(frames_by_dts[d][1] for d in main_dts_order if d in frames_by_dts)

    # Find raw audio .pts (PTSDumpLogger 6-col format, NOT .pts.final.pts)
    audio_pts_raw = _find_audio_pts_file(search_dir, base_filename)
    if audio_pts_raw is None:
        print(f"\n⏭️  audio .pts 不存在（无 audio dump 或未启用 PTSDumpLogger），跳过 audio trim")
        return

    # Detect audio segments by >5s PTS jumps (same threshold as pts_finalize)
    audio_segments = _detect_audio_segments_from_pts(audio_pts_raw)
    if not audio_segments:
        print(f"\n⏭️  audio .pts 无有效行（空文件？），跳过 audio trim")
        return

    # Pick longest segment as main audio segment
    main_audio_seg = max(audio_segments, key=lambda s: s['frame_count'])
    audio_first_idx = main_audio_seg['start_idx'] + 1  # 转 1-based frame_index
    audio_last_idx = main_audio_seg['end_idx'] + 1

    print(f"\n📊 audio segments (from raw {audio_pts_raw.name}, no pts_finalize):")
    for i, seg in enumerate(audio_segments):
        first_pts = seg['first_pts'] / 1_000_000
        last_pts = seg['last_pts'] / 1_000_000
        span = last_pts - first_pts
        marker = "  ← MAIN" if seg is main_audio_seg else ""
        print(f"    [{i}] {seg['frame_count']:5d} frames, "
              f"pts={first_pts:.3f}s..{last_pts:.3f}s (span {span:.3f}s){marker}")

    # audio_file 必须容忍 .p1 后缀（capture.sh 传进来的 base_filename 不含 .p1，但
    # dump 文件是 monitor 滚动后加上 .p1 的。video 那边 .p1.h264 兑底已有，照加一份给 audio。
    audio_file = search_dir / f"{base_filename}.p1.aac"
    if not audio_file.exists():
        audio_file = search_dir / f"{base_filename}.aac"
    if not audio_file.exists():
        print(f"\n⏭️  audio .aac dump 不存在（无 audio dump 或 file 不匹配），跳过 audio trim")
        return
    audio_backup = audio_file.with_suffix(audio_file.suffix + '.original')
    trim_audio(audio_file, audio_backup,
               video_first_kept_pts, video_last_kept_pts,
               audio_first_idx, audio_last_idx)


if __name__ == '__main__':
    main()