# firefox-stream-fetch

在 Firefox **CDM 解密完成后、解码开始前**截获原始视频码流，输出为 H.264 Annex B 裸流（可被 ffplay 直接播放，或用 ffmpeg `-c copy` 重封装为 mp4）。

## 与姊妹项目的关系

| 项目 | hook 点 | 输出格式 | 画质 |
|---|---|---|---|
| [firefox-frame-dump](../firefox-re) | FFmpegVideoDecoder 输出（YUV 像素） | 裸 I420 `.yuv` 文件 | 必须再编码，**有损** |
| **firefox-stream-fetch（本项目）** | MSE+CDM 输出（H.264 码流） | Annex B `.h264` 裸流 | **无损** |

## 研究目标

视频网站 → 网络传输 → CDM (Widevine) 解密 → MediaRawData → 解码器 → 渲染
                                       ↑ 我们要把这一步存下来

拿到的数据是**已解密但仍压缩**的 H.264 NALU 流，重新拼接成 MP4 后，**画质与原网站视频等同**。

## 工作目录

```
firefox-stream-fetch/
├── README.md         # 本文件
├── NOTES.md          # 分析笔记
├── firefox/          # Firefox 源码（不入 git，与姊妹项目不共享）
├── patches/          # 新 patch（与 firefox-re 的 patch 独立）
├── scripts/          # 构建/测试脚本（多数可复用 firefox-re 的）
├── dumps/            # 截获的视频流（不入 git）
└── .gitignore
```

## 流程

1. 克隆 Firefox 源码（或复用 firefox-re/firefox，加上新 patch）
2. 在 `MediaSourceEngine` / `MediaFormatReader` / `TrackBuffers` 路径找到 hook 点
3. 写 patch：在解密后的 `MediaRawData` 写入标准 MP4 容器
4. 编译运行，验证输出可以直接 `ffplay` 播放

## 状态

- [x] 仓库创建，目录骨架
- [x] GitHub 仓库链接
- [x] 定位 hook 点（MediaFormatReader::HandleDemuxedSamples + OnVideoDemuxCompleted 双 hook）
- [x] 写 patch
- [x] 编译 + 本地 mp4 验证通过（913 帧 36.5s mp4 dump，可 ffplay/转封装）
- [x] **AAC 音频 dump 验证通过（10s 测试流 → 音视频双轨 mp4）**
- [ ] Widevine L3 真实内容验证（需手动播放确认 hook 对 EME 路径同样工作）
- [ ] 编译 + 测试


## 版本记录

### v3.2.0 (2026-07-21)

**dump PTS 化 + PyAV mux + 切集检测升级**

| 维度 | 内容 |
|---|---|
| **dump 格式** | 新格式 SDFV（视频）/ SDFA（音频）：文件头 magic + 每帧 [size(4)][pts_us(8)][data] |
| **解析器** | `sdfv_extract.py`：dump → .raw + .pts；支持 `--last-pts-only` 快速读最后一帧 PTS |
| **mux 路径** | 新增 `mux_with_pts.py`（PyAV）：raw + pts → mp4/m4a，每帧写入真实 PTS；ffmpeg `-c copy` 合并保留双方 PTS 时间轴 |
| **切集检测** | 三信号 OR：bidi-state / firefox URL 变化 / dump PTS 跳变；移除 ct/duration 启发式守卫 |
| **Fallback 链** | PyAV 失败 → ffmpeg fps；解析失败 → ffprobe 探测 |
| **StreamDumper 每帧 log** | 从每 100 帧节流改为无条件 log，便于调试 PTS 连续性 |

### v3.1.0 (2026-07-17)

| 维度 | 内容 |
|---|---|
| **核心成果** | `--auto-next` 正式可用：playlist 自动连集，每集独立 `host-01.mp4`, `host-02.mp4`... |
| **切集检测** | BiDi 轮询时双信号确认：`location.href` 变化 + `<video>.currentSrc` 变化 + `readyState >= 2` |
| **数据流** | monitor 写 sidecar `next_url` + `episode_index` → capture.sh 循环读取 → Phase 2 重跑 |
| **命名** | 固定顺序命名 `{host}-{02d}.mp4`（无需额外参数） |
| **回退** | 无下一集 / 用户未开 `--auto-next` → 单集正常结束 |

**后续修复 (d4a87c6)**

- **音画同步自动探测**：`mux_to_mp4` 中用 `ffprobe` 探测真实 `avg_frame_rate` / `sample_rate` / `channels`，替代硬编码 `-r 25` / `-ar 44100 -ac 2`
- **next_episode 误判修复**：加入守卫条件 `current_time > 30s && duration > 60s`，避免页面预加载/清晰度切换触发的 `src` 变化被误判为下一集
- **仅保留 URL 变化检测**：移除 `video.src` 兜底，减少误触发
- **firefox 路径兼容**：支持 `obj-x86_64-pc-linux-gnu` 目录名查找 Firefox 二进制
- **文档更新**：使用说明补充无 URL 启动模式、排查章节加入 `watch` 实时监控命令

---

### v3.0.0 (2026-07-17)

**统一抓取入口、保留两阶段架构、环境变量代理、兼容旧脚本**

| 维度 | 内容 |
|---|---|
| **核心成果** | 4 个 site 适配脚本合并为 1 个 `capture.sh`；旧脚本保留为 1 行 shim 兼容
| **架构** | Phase 1（过验证/加载，sandbox 开） → Phase 2（抓流，sandbox 关）两阶段保留
| **代理策略** | 统一读 `http_proxy/https_proxy/all_proxy` 环境变量；Phase 1 显式 unset 避免 CF 检测
| **输出目录** | 默认 `~/Videos/firefox抓取/`，文件名 `<host>-<timestamp>.mp4`
| **监控** | lib-monitor.sh 智能监控（BiDi 5s 轮询 video.state + ended/stall/paused/no-video + 自动恢复 ≤3 次）
| **反指纹** | Phase 1 最小 prefs（真实 UA + sandbox 开），Phase 2 关 sandbox 允许写盘
| **音视频** | H.264/HEVC/AV1 自动 dispatch + AAC 双轨，合流 ffmpeg `-c copy`
| **兼容** | `capture-olevod.sh/youtube.sh/yfsp.sh` 透传参数到 `capture.sh`
| **验证** | olevod.com 明文流端到端跑通（178MB h264 + 11MB aac → mp4）

---

### v2.2.0 (2026-07-16)

**修复：Phase 1 → Phase 2 真正能自动切换（CF 反检测）**

问题：
- `capture-generic.sh` Phase 1 启动时加了 `-remote-debugging-port` 和 BiDi 轮询检测 video state
- CF Turnstile 会检测 devtools-protocol 端口作为 bot 信号 → yfsp.tv 等反复弹人机验证
- BiDi 在 cross-origin iframe 场景下也读不到 video state

修复：
- `scripts/capture-generic.sh` Phase 1 去掉 `-remote-debugging-port` 和 BiDi 检测
- 改用纯 X11 窗口标题检测（与稳定的 `capture-yfsp.sh` 一致）：`Just a moment...` → 视频页面标题 → 触发切换
- `get_firefox_wid` 优先匹配 "Nightly" 标签页窗口，避免选到 URL 栏等没标题的子窗口
- `bidi-state.py` `no-video` 状态也返回 `url` 字段（可跳用补点）

实战验证：
- yfsp.tv `https://www.yfsp.tv/watch?v=ztgsSWh5mPZEhhazLjYUG6`
- 18s 过 CF → Phase 1 → Phase 2 自动切换
- 产出 h264 19.8MB + aac 415KB → mux 成 2:21 mp4 (320x240 H.264 + AAC stereo)
- 抽帧确认是 "Linya bilibili" vlog 真实内容

### v2.1.0 (2026-07-15)

**新增：解密后 AAC 音频 dump（与视频同时写出）**

改动：
- `dom/media/MediaFormatReader.cpp`：StreamDumper 在 `HandleDemuxedSamples` 里按 TrackType 分支
  - `kVideoTrack` → 现有路径（H.264/HEVC/AV1 裸码流）
  - `kAudioTrack` → 新 `DumpAudio()`，用 Mozilla 自带的 `ADTS::ConvertSample` 把 AAC 包成 ADTS 帧
- 音频输出路径：`MOZ_STREAM_DUMP_PATH` 去掉视频扩展名后加 `.aac`
  - `MOZ_STREAM_DUMP_PATH=/tmp/foo.h264` → 视频 `/tmp/foo.h264` + 音频 `/tmp/foo.aac`
  - 默认（无环境变量）→ `/tmp/moz_stream.h264` + `/tmp/moz_stream.aac`
- 合流：`ffmpeg -i video.h264 -i audio.aac -c copy out.mp4`

新脚本：
- `scripts/verify-audio.sh` — end-to-end 验证（生成测试 mp4、起 firefox、探测 .h264/.aac 双 dump、ffprobe 识别、ffmpeg 合流、断言双轨）

验证（10s 合成的 H.264 + AAC 测试流）：
- `ffprobe audio.aac`：AAC LC, 44100 Hz, mono, 86 kb/s, 10.16s
- `ffprobe merged.mp4`：10.03s, Stream #0:0 Video H.264, Stream #0:1 Audio AAC

Patches：
- `patches/0004-add-audio-dump.patch` — v2.1.0 DumpAudio + 路径 trim

### v2.0.0 (2026-07-14)

- **CF Turnstile 反反爬解决方案**：两阶段法
  - Phase 1：sandbox 正常 → 手动过 CF → cookie 落盘
  - Phase 2：sandbox 关闭 + cookie 复用 → 自动抓取
- **capture-generic.sh 通用脚本**：支持任意 URL、session restore、无 URL 模式
- 自动 ffmpeg 转 .mp4 + 清理中间文件
- 多集自动抓取（--auto-next）
- 配置化输出目录（--output，默认 ~/Videos/firefox抓取/）
- 启动后拉窗口到前台

### v1.1.0 (2026-07-13)

**新增 video/av1 支持 + IVF 容器自动包装 + codec-aware 文件后缀**

改动：
- `dom/media/MediaFormatReader.cpp`：StreamDumper class 加 `video/av1` codec dispatch
- AV1 sample 走 IVF 容器自动包装路径：32-byte IVF file header + 每个 sample 一个 IVF frame（12-byte frame header + OBU 字节流）
- 自动按 codec 选择文件后缀：
  - H.264 → `/tmp/moz_stream.h264`
  - HEVC  → `/tmp/moz_stream.h265`
  - AV1   → `/tmp/moz_stream.av1`
  - 显式 `MOZ_STREAM_DUMP_PATH=xxx` 时按字面路径写
- AV1 第 1 帧 prepend `mExtraData[4:]`（跳过 av1C config 的 4 字节，留 OBU(s)），让 IVF frame 自带 init

新脚本：
- `scripts/capture-youtube.sh` — 持久化 profile + YouTube AV1 抓取（自动 IVF）
- `scripts/capture-olevod.sh` — olevod.com H.264 直连，**无代理**（olerod 直连可达）
- `scripts/capture-yfsp.sh` — yfsp.tv 测试脚本，含 CF cookie 持久化

验证（YouTube `_n4SRDYkhqs`）：
- 39MB IVF/AV1 自动写出
- ffprobe: AV1 Main, 1080×608, yuv420p, BT.709
- ffmpeg 抽帧：拿到真实视频帧画面（两人在工作室）

Patches：
- `patches/0001-dump-stream.patch` — v1.0.0 H.264 dump
- `patches/0002-add-av1-support.patch` — v1.1.0 codec dispatch
- `patches/0003-codec-aware-output.patch` — v1.1.0 IVF + auto-suffix

### v1.0.0 (2026-07-11)

初始发布：H.264 dump，Annex B + SPS/PPS。

## 限制

- 仅对 **L3 软件解密**有效（桌面 Linux 默认）
- 仅对 **H.264/AVC** 内容有效（最常见）；H.265/AV1 需要适配
- 仅供研究/学习，请遵守当地法律
