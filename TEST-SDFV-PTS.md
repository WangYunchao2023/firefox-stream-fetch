# SDFV/SDFA PTS 格式测试说明

## 改动摘要

### 1. StreamDumper C++ (`firefox/dom/media/MediaFormatReader.cpp`)
- **视频 dump 新格式 (SDFV)**:
  - 文件头：`SDFV` magic (4B) + version (1B) + reserved (3B) + header_len (4B) + SPS/PPS
  - 每帧：`frame_size` (4B LE) + `PTS_us` (8B LE) + `frame_data`
  
- **音频 dump 新格式 (SDFA)**:
  - 文件头：`SDFA` magic (4B) + version (1B) + reserved (3B)
  - 每帧：`frame_size` (4B LE) + `PTS_us` (8B LE) + `adts_data`

### 2. Python 解析器 (`scripts/sdfv_extract.py`)
- 输入：`.h264` 或 `.aac` dump 文件（新格式）
- 输出：`.raw` (裸流) + `.pts` (每帧 PTS，微秒)
- 支持 PTS 偏移参数：`python3 sdfv_extract.py <dump> [pts_offset_us]`

### 3. Mux 封装 (`scripts/capture.sh:mux_to_mp4`)
- 自动检测 SDFV/SDFA 格式
- 单段：按 `fps = N_frames / (last_pts - first_pts)` 计算准确帧率
- 多段：累加 PTS 偏移，无缝拼接
- Fallback: 旧格式或解析失败时用 ffprobe 探测

## 测试步骤

### 1. 手动 URL 模式（无 URL 参数）
```bash
cd ~/Documents/软件类工作/firefox-stream-fetch
./scripts/capture.sh
```
- Phase 1: Firefox 启动，手动输入 `https://www.yfsp.tv/play/zImbBGABDR2`
- 过 Cloudflare 验证
- Phase 2: 同 profile 重新打开 Firefox，自动开始抓取

### 2. 预期输出
```
📦 解析 SDFV dump + 提取每帧 PTS...
frames=7500 first_pts=1234567us last_pts=301234567us span=300.000s
✅ PTS: 7500 帧，时长 300.000s, fps=25.0000
🎬 封装 → /home/wangyc/Videos/firefox抓取/manual-TIMESTAMP.mp4
  ✅ mp4: ...
    duration: 300.000000
    codec_name: h264, aac
```

### 3. 验证要点
- [ ] mp4 时长 ≈ 300s (5 分钟)
- [ ] 音画同步（无明显偏移）
- [ ] 无重复帧/跳帧
- [ ] 切集检测正确（如开启 AUTO_NEXT）

## 回退方案

如新格式有问题，可临时禁用：
1. 注释 StreamDumper 的 PTS 写入代码
2. 恢复 `capture.sh` 使用旧版 `mux_to_mp4`（git 回滚）

## 文件格式对比

| 格式 | 旧版 | 新版 (SDFV/SDFA) |
|------|------|------------------|
| 视频头 | SPS/PPS 裸写 | magic + header_len + SPS/PPS |
| 视频帧 | 裸 NAL | size(4) + PTS(8) + NAL |
| 音频头 | 无 | magic(8B) |
| 音频帧 | 裸 ADTS | size(4) + PTS(8) + ADTS |
| 时长计算 | sidecar.duration / 帧数估算 | 精确 PTS 差值 |
| 多段拼接 | concat demuxer（时间可能跳跃） | PTS 偏移累加（平滑） |

## 已知限制

- 旧 dump 文件（无 magic）会被解析器拒绝，自动 fallback 到 ffprobe
- 音频 PTS 暂未用于音画同步校准（CPU 限制，ffmpeg 会自动处理）
- PTS 跳变（切集）依赖 next_episode 检测 + 分段 dump，解析器仅做偏移累加

---
最后更新：2026-07-21 15:14
Firefox 版本：基于 firefox-stream-fetch patches + SDFV commit