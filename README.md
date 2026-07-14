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
- [ ] Widevine L3 真实内容验证（需手动播放确认 hook 对 EME 路径同样工作）
- [ ] 编译 + 测试


## 版本记录

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
