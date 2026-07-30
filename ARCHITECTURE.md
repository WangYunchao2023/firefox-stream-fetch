# firefox-stream-fetch 架构文档

> 记录本项目的组件划分、数据流、关键设计决策。
> 最后更新：2026-07-30（v3.2）

---

## 1. 项目目标

在 Firefox **CDM 解密完成后、解码开始前**截获原始视频码流，输出为可被 ffplay 直接播放的裸流格式。

核心路径：`视频网站 → 网络传输 → CDM (Widevine) 解密 → MediaRawData → 解码器 → 渲染`
在箭头 ↑ 处截获已解密但仍压缩的码流。

---

## 2. 整体架构图

```
┌──────────────────────────────────────────────────────────────────┐
│                        用户交互层 (Phase 1)                      │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  capture.sh 启动 Firefox (sandbox 开, 真实 UA)             │   │
│  │  → 用户手动过 CF Turnstile / 输入 URL                      │   │
│  │  → 窗口标题检测 + places.sqlite URL 提取                   │   │
│  │  → SIGTERM 退出，保存 session/cookie                       │   │
│  └──────────────────────────────────────────────────────────┘   │
└──────────────────────┬───────────────────────────────────────────┘
                       │ places.sqlite / .phase1_url / cookies.sqlite
                       ▼
┌──────────────────────────────────────────────────────────────────┐
│                        抓取层 (Phase 2)                          │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  capture.sh — 统一入口                                     │   │
│  │  ├── 关 sandbox (security.sandbox.* = 0)                  │   │
│  │  ├── 启动 Firefox (sandbox 关, 同 profile + cookie)       │   │
│  │  └── 调用 monitor_run (lib-monitor.sh)                   │   │
│  └──────────────────────────────────────────────────────────┘   │
└──┬────────────────────────────┬─────────────────────────────────┘
   │                            │
   ▼                            ▼
┌───────────────┐      ┌──────────────────────┐
│ Firefox 进程  │      │ lib-monitor.sh       │
│               │      │ (智能监控主循环)       │
│ StreamDumper  │      │                      │
│ (C++ patch)   │      │ ┌─ BiDi daemon       │
│               │      │ │ (bidi-state.py)    │
│ 拦截 MediaRaw-│      │ │   ┌─ TCP 9222      │
│ Data 后写出   │      │ │   │ 连 Firefox      │
│               │      │ │   └─ 每 5s 查       │
│ .h264/.aac    │      │ │     video state    │
│ (SDFV/SDFA)   │      │ └─ 状态机:           │
│               │      │   playing/paused/    │
│               │      │   buffering/         │
│               │      │   ended/no-video     │
│               │      │   next_episode       │
│               │      │ └─ 崩溃自动恢复 ≤3 次  │
│               │      └──────────────────────┘
│               │      └─ sidecar JSON       │
│               │         (lib-sidecar.sh)   │
│               │         记录进度/断点       │
└───────┬───────┘
        │
        ▼
┌──────────────────────────────────────────────────────────────────┐
│                        后处理层                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  capture.sh — mp4 合并                                     │   │
│  │  ├── sdfv_extract.py: SDFV/SDFA → .raw + .pts            │   │
│  │  ├── mux_with_pts.py: raw + pts → mp4 (PyAV)             │   │
│  │  │   └─ fallback: ffmpeg -c copy                         │   │
│  │  ├── 音画自动同步 (ffprobe 探测真实 fps/ar/ch)              │   │
│  │  └─ 切集检测 (PTS 跳变 OR URL 变化)                       │   │
│  └──────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
        │
        ▼
  ~/Videos/firefox抓取/<host>-NN.mp4
```

---

## 3. 组件详解

### 3.1 Firefox Patch 层 (`patches/` + `firefox/dom/media/MediaFormatReader.cpp`)

**唯一修改的源文件：** `firefox/dom/media/MediaFormatReader.cpp`

**修改方式：** 5 个 patch 叠加应用（见 4.1 节 patch 叠加关系）

**核心类：** `StreamDumper`（C++ 内嵌类），功能：

| 功能 | 说明 |
|---|---|
| Codec dispatch | 自动识别 H.264/HEVC/AV1（按 `mMimeType` 首次匹配后锁定） |
| H.264 输出 | AVCC → Annex B（用 Mozilla 内置 `AnnexB::ConvertAVCCSampleToAnnexB`） |
| HEVC 输出 | HVCC → Annex B（用 `AnnexB::ConvertHVCCSampleToAnnexB`） |
| AV1 输出 | 原始 OBU 透写 + 可选 IVF 容器包装 |
| AAC 音频 | ADTS 帧头自动包装（用 Mozilla 内置 `ADTS::ConvertSample`） |
| PTS 写入 | 每帧 `aSample->mTime` 写入文件头（SDFV/SDFA 格式 v1） |
| 预热跳过 | 丢弃前 30 个 sample（Firefox 启动 warmup） |

**双 Hook 点：**

| Hook 点 | 触发路径 | 适用场景 |
|---|---|---|
| `OnVideoDemuxCompleted` | MSE/EME + CDM 路径 | HLS、ClearKey、Widevine L3 |
| `HandleDemuxedSamples` 内 `DecodeDemuxedSamples` 前 | 直接 src=MP4 路径 | 直链、file://、HTTP(s) MP4 |

**关键设计决策：**
- TrackInfo 来源：优先调用方传入 `aInfo`（`decoder.GetCurrentInfo()`），fallback `aSample->mTrackInfo`（MP4Demuxer 不设置）
- 输出路径：`MOZ_STREAM_DUMP_PATH` 环境变量，默认 `/tmp/moz_stream.h264`
- 音频文件：自动去视频扩展名 + `.aac`（如 `foo.h264` → `foo.aac`）

### 3.2 抓取编排层 (`scripts/capture.sh`)

**职责：** 统一入口脚本，协调 Phase 1 → Phase 2 → mp4 合并

**Phase 1（用户交互）：**
1. 启动 Firefox（sandbox 开、真实 UA、不开 BiDi）
2. 轮询窗口标题（`xdotool`），检测 "Just a moment..."（CF）→ 真实页面标题
3. 页面标题变化后等 5s，SIGTERM 关闭 Firefox
4. 从 `places.sqlite`（主）/ sessionstore 兜底提取实际 URL
5. 验证 `cf_clearance` cookie 是否落盘

**Phase 2（自动化抓取）：**
1. 重写 `user.js`/`prefs.js`（关 sandbox、关 session restore）
2. 启动 Firefox + BiDi daemon + `lib-monitor.sh` 监控
3. 等待视频元素出现 + 播放，开始写 dump
4. 智能监控：stall 累计、崩溃恢复、ended 检测
5. 切集检测（`--auto-next`）：URL 变化 + src 变化 + 播放时长守卫
6. 输出 `.h264/.aac` → `mux_to_mp4` → `.mp4`
7. 可选循环（`--auto-next`）：继续下一集

**代理策略：**
- Phase 1：显式 unset 所有 proxy 环境变量（防 CF 检测）
- Phase 2：透传 `*proxy` 环境变量给 Firefox

**Profile 管理：**
- 按 URL host 自动命名（`/tmp/firefox-stream-{host}`）
- 也可 `--profile PATH` 指定

### 3.3 监控守护 (`scripts/lib-monitor.sh`)

**职责：** Phase 2 的智能监控主循环

**状态机：**
```
playing + dump_growing    → stall_count = 0 (正常)
paused                    → 不增 (用户主动暂停)
buffering                 → stall_count 减半 (网络问题)
playing + !dump_growing   → stall_count++ (异常停滞)
ended                     → 结束
no-video                  → 恢复 (崩溃/元素消失)
firefox 死亡              → 自动重启 + seek 到 last_keyframe_pts
```

**自动恢复：** firefox 崩溃时最多自动重启 3 次（`MONITOR_MAX_INTERRUPTS=3`）

**超时策略：**
- stall 累计 36 次（180s）→ 判定结束
- 暂停 360 次（30min）→ 判定结束

### 3.4 Sidecar 持久化 (`scripts/lib-sidecar.sh`)

**格式：** JSON 文件，存在 dump 文件旁边（`.sidecar.json`）

**用途：** 记录 Phase 2 运行状态，支持 resume 和调试

**关键字段：**
| 字段 | 类型 | 说明 |
|---|---|---|
| `video_state` | string | playing/paused/buffering/ended |
| `current_time` | number | 当前播放进度 (s) |
| `last_dump_size_video` | number | 上次探测的视频 dump 大小 (bytes) |
| `last_keyframe_pts` | number | 最后一帧 PTS (us)，用于崩溃恢复 seek |
| `interrupt_count` | number | 崩溃恢复次数 |
| `interrupt_reasons` | string[] | 每次中断原因 |
| `parts` | array | 分段记录（自动连集） |
| `next_episode_url` | string | 下一集 URL（切集检测时写入） |

### 3.5 BiDi 守护 (`scripts/bidi-state.py`)

**两种模式：**

| 模式 | 用法 | 说明 |
|---|---|---|
| `daemon` | `bidi-state.py daemon --port 9222` | 长驻，TCP 9222 → unix socket，复用单一 BiDi session |
| `query` | `bidi-state.py query --port 9222` | 单次查询（不推荐，多次调用会触发 session 清理） |

**命令协议：**

| cmd | 输入 | 输出 |
|---|---|---|
| `query` | `{"url_pattern": ".*"}` | `{"state": "playing", "currentTime": 12.3, ...}` |
| `seek` | `{"seconds": 120.5}` | `{"ok": true, "newTime": 120.5}` |
| `stop` | `{}` | daemon 退出 |
| `ping` | `{}` | `{"ok": true}` |

**video state 值：** `playing` / `paused` / `buffering` / `ended` / `no-video` / `next_episode` / `unknown`

**next_episode 检测：** 双信号 + 守卫条件
- `location.href` 变化 AND `<video>.currentSrc` 变化 AND `readyState >= 2` AND `currentTime > 30s` AND `duration > 60s`

### 3.6 Dump 解析器 (`scripts/sdfv_extract.py`)

**SDFV（视频）格式 v1：**
```
[4B magic "SDFV"][1B version][3B reserved][4B header_len LE][header_data (SPS/PPS)]
每帧: [4B frame_size LE][8B pts_us LE][frame_data (frame_size bytes)]
```

**SDFA（音频）格式 v1：**
```
[4B magic "SDFA"][1B version][3B reserved]
每帧: [4B frame_size LE][8B pts_us LE][frame_data (frame_size bytes)]
```

**输出：**
- `<prefix>.raw` — 拼接所有 frame_data（无 PTS，兼容老工具）
- `<prefix>.pts` — 每帧 PTS（微秒），一行一个

### 3.7 MP4 合并 (`scripts/mux_with_pts.py`)

**流程：**
1. 读取 `.raw` + `.pts`
2. 验证 PTS 可信度：PTS span < n_frames/30s 说明 Firefox MSE 的 mTime 不可信
3. 若 PTS 不可信：以音频时长推算视频帧间隔（最准），否则退回到相邻 PTS 差值中位数
4. 用 PyAV 按每帧真实 PTS 写入 mp4
5. Fallback：PyAV 失败 → ffmpeg fps 合并

---

## 4. 文件清单

```
firefox-stream-fetch/
├── README.md                    # 项目简介 + 使用说明
├── NOTES.md                     # 分析笔记（踩坑记录、诊断输出）
├── 关键版本记录.md               # 版本编年史
├── 使用说明.md                   # 详细使用指南
├── TEST-SDFV-PTS.md             # SDFV/PTS 测试说明
├── ARCHITECTURE.md              # ← 本文档
├── INTERFACES.md                # ← 接口文档（另起）
├── mozconfig                    # Firefox 构建配置
│
├── patches/                     # 5 个 patch（叠加修改 MediaFormatReader.cpp）
│   ├── 0001-dump-stream.patch       # v1.0.0：H.264 基础 dump
│   ├── 0002-add-av1-support.patch   # v1.1.0：codec dispatch（HEVC/AV1）
│   ├── 0003-codec-aware-output.patch# v1.1.0：IVF 容器 + 自动后缀
│   ├── 0004-add-audio-dump.patch    # v2.1.0：AAC 音频 dump
│   └── 0005-stream-source-tracking.patch # v3.2：预热跳过 + stream reset
│
├── scripts/                     # 运行时脚本
│   ├── capture.sh               # ★ 统一入口（Phase 1 + Phase 2 + mux）
│   ├── lib-monitor.sh           # 智能监控主循环（依赖 lib-sidecar + bidi-state）
│   ├── lib-sidecar.sh           # sidecar JSON 持久化
│   ├── bidi-state.py            # BiDi daemon / query / seek
│   ├── sdfv_extract.py          # SDFV/SDFA dump → raw + pts
│   ├── mux_with_pts.py          # raw + pts → mp4 (PyAV)
│   ├── capture-olevod.sh        # shim → capture.sh
│   ├── capture-youtube.sh       # shim → capture.sh
│   ├── capture-yfsp.sh          # shim → capture.sh
│   ├── capture-<site>.sh        # shim（透传参数）
│   ├── verify-*.sh              # 各种验证脚本
│   ├── check-*.sh               # 诊断脚本
│   └── apply_timestamps.py      # PTS 时间戳应用
│
├── firefox/                     # Firefox 源码（不纳入 git）
│   ├── dom/media/MediaFormatReader.cpp  # ★ 唯一被 patch 的文件
│   └── [大量 Mozilla 源码]
│
├── obj-stream/                  # 编译输出（不纳入 git）
│   └── dist/bin/firefox         # patched Firefox 二进制
│
├── dumps/                       # 截获的视频（不纳入 git）
│   └── v2.2.0-verification/
│
├── memory/                      # 项目记忆
│   ├── 2025-07-12-olevod-verification.md
│   └── 2026-07-21.md
│
└── notes/                       # 空目录
```

---

## 5. Patch 叠加关系

所有 patch 都修改同一个文件：`firefox/dom/media/MediaFormatReader.cpp`

```
原始文件
  │
  ▼ 0001 (v1.0.0)
+ StreamDumper 基础类（仅 H.264，仅视频）
│  └─ 双 hook 点（OnVideoDemuxCompleted + HandleDemuxedSamples）
│
  ▼ 0002 (v1.1.0)
+ Codec dispatch：H.264 / HEVC / AV1
│  └─ sCodecId 锁定机制
│
  ▼ 0003 (v1.1.0)
+ IVF 容器自动包装（AV1）
│  └─ 自动文件后缀（.h264/.h265/.av1）
│
  ▼ 0004 (v2.1.0)
+ DumpAudio()：AAC 音频 dump
│  └─ ADTS 帧头自动包装
│
  ▼ 0005 (v3.2)
+ 预热跳过（前 30 个 sample）
│  └─ stream state 声明提升 + gAudioDumpFile
│
最终编译
```

**注意：** 每次新增 patch 需要重新 `./mach build`（Firefox 完整编译约 15-20 分钟）。

---

## 6. 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `MOZ_STREAM_DUMP_PATH` | `/tmp/moz_stream.h264` | dump 输出路径 |
| `DISPLAY` | `:1` | X11 display |
| `XAUTHORITY` | `/run/user/1000/gdm/Xauthority` | X11 auth |
| `MOZ_ENABLE_WAYLAND` | `0` | 强制 X11 |
| `GDK_BACKEND` | `x11` | GDK X11 backend |
| `http_proxy` 等 | — | 代理（Phase 2 透传） |

---

## 7. 已知限制

1. **仅限 L3 软件解密**（桌面 Linux 默认）— L1 hardware 解密无法截获
2. **不支持 VP9** — Codec dispatch 中 `video/vp9` 未实现
3. **Phase 1 URL 提取依赖 places.sqlite** — 极端情况下可能为空
4. **编译时间很长** — 每次 patch 变化需重新编译 Firefox
