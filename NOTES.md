# 分析笔记

## 数据管线定位（按数据流动顺序）

```
[ELEMENT 网络层]
  fetch(encrypted m3u8 / manifest)
  ↓
[HTMLMediaElement / MediaSource]
  SourceBuffer.appendBuffer(encrypted chunk)
  ↓
[SourceBuffer 状态机]    ← 这里拿到的是 CENC 加密的 sample
  track_buffer.cpp: queued segments
  ↓
[CDM 平台适配 (Widevine CDM)]
  dom/media/eme/  ← 这是 CDM 与 Firefox 的接口层
  emecontroller.cpp: CDMProxy::Session()
  ↓
[CDM IPC: Chrome ↔ Sandbox(GMP)]
  GMPVideoDecoder
  GMPVideoFrame (DecryptedFrame)
  ↓ ★★★ 我们的最佳 hook 点 ★★★
  dom/media/MediaRawData.cpp  MediaData 层级
  ↓ 解码器拿到 packet
[FFmpegVideoDecoder::Decode]
  从这里开始就是已有的 firefox-re patch 的范围
  ...
```

## 关键候选 hook 点

### A. `dom/media/mediasource/TrackBuffers.cpp` — SourceBuffer::AppendBufferToTrackBuffer

在这里可以拦截**所有**送给解码器的 packet，但此时数据可能还在 PSSH/key 流程中，不一定全部解密完。

### B. `dom/media/eme/EMEDecoderModule.cpp` — 平台 → FFmpeg 路径

CDM 返回的 `DecryptedBuffer` 在这里被映射成 `MediaRawData`。**完美的 hook 点**：
- 数据已经解密
- 数据仍是 H.264 NALU 格式（已压缩）
- 还没进解码器，自然没渲染过

### C. `dom/media/MediaData.cpp` 中间层

MediaData → MediaRawData 的转换点，比较通用但定位不如 B 精确。

## 输出方案

不直接写裸 H.264，而是用 FFmpeg/MP4 muxer 实时封装：

### 方案 1：fragment MP4 文件（推荐）

```
dump/
├── manifest.json
├── init.mp4         # moov/trak/mvex 等
├── segment-00001.m4s
├── segment-00002.m4s
├── ...
```

ffmpeg 可以直接拼接播放，也可以用 `--enable-trimming-remux` 合并成单个 mp4。

### 方案 2：增量 fragment 单文件

所有 fragment 都 append 到同一个 .mp4 文件，自动处理 init segment。简单但易出问题。

## 复用 vs 重建

**原 firefox-re 项目的源码和 objdir 可以 100% 复用**，但要走完全分离的路线：

| 资源 | 复用 | 单独 |
|---|---|---|
| firefox 源码 | ✅ 可考虑软链或直接复用 | 也可新建 |
| objdir (18GB) | ❌ 不能复用（patch 已改 FFmpegVideoDecoder） | 需新建 |
| 系统依赖 | ✅ 完全复用 | — |
| Widevine CDM | ✅ 完全复用（21MB） | — |

最干净的做法：**复用 firefox-re/firefox 源码作为基础，添加新的 patch，重新编译到 firefox-stream-fetch/obj-stream/**，最终得到一个新的 firefox-stream 二进制。这样：
- 节省 ~5GB 源码 disk
- 节省 30+ 分钟克隆时间
- 不损失独立性（patch 独立、objdir 独立、二进制独立）

## 下一步

1. ~~确认仓库命名~~ ✓ `firefox-stream-fetch`
2. 创建 GitHub 仓库
3. 复用 firefox-re/firefox 源码
4. 研究 EMEDecoderModule.cpp 的数据流
5. 写 patch：捕获 decrypted MediaRawData，写入 fragment MP4
6. 编译、测试
