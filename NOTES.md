# Stream-Fetch 实验笔记

## 项目目标
在 Firefox **CDM 解密完成后、解码开始前**截获 H.264 NALU 流。

## Hook 点选择

候选位置对比：
| 位置 | 文件 | 触发时机 | 拿到什么 |
|---|---|---|---|
| 网络层 | NetworkObserver | DRM 解密**前** | CENC 加密段，不能用 |
| MSE | SourceBuffer/TrackBuffers | 解密混合期 | 部分解密，部分加密 |
| **MediaFormatReader** | HandleDemuxedSamples | **解密后、解码前** ✓ | **已解密的 H.264 NALU** |
| FFmpegVideoDecoder | CreateImage | 解码后 | YUV 像素（firefox-re 方案） |

**选 MediaFormatReader::HandleDemuxedSamples** 作为最终 hook 点。

## 实现细节

**修改文件：** `dom/media/MediaFormatReader.cpp`

**插入位置：** `HandleDemuxedSamples` 函数中 `DecodeDemuxedSamples(aTrack, sample)` 调用前

**StreamDumper 类的功能：**
1. 只处理视频轨 (`kVideoTrack`)
2. 只处理 H.264 AVC (`video/avc` mime)
3. 从 `MOZ_STREAM_DUMP_PATH` 环境变量读 dump 文件路径
4. 第一次写 SPS/PPS header (用 `AnnexB::ConvertAVCCExtraDataToAnnexB`)
5. 后续每个样本：转 AVCC → Annex B (用 `AnnexB::ConvertAVCCSampleToAnnexB`)
6. 写入文件，附带 metadata (frame count, time, size)

## 编译过程

### 第一次构建（11:08-11:25，17 分钟）
- ✅ 完整编译 0 错误
- ❌ 但**编译错误**真正出现在 `dom/media/MediaFormatReader.cpp`：
  1. `mozilla::TrackType` 应为 `mozilla::TrackInfo::TrackType`
  2. `vi->mMimeType.begin()` nsCString 没 `.begin()`
  3. `spsPps->Data()` MediaByteBuffer 是 nsTArray，应该 `.Elements()`

### 错误修复后增量编译（2:13 极快）
- ✅ 0 错误，链接成功
- ✅ `libxul.so` 3.4GB
- ✅ 二进制中 StreamDumper 字符串出现 16 次

## 踩的坑

### 坑 1: unified 编译机制
Mozilla 用 Unified_cpp_dom_media*.cpp 把多个 .cpp 合并编译。文件被 `git diff` 发现但不一定在统一 cpp 中生效。**只有当源 .cpp 文件 mtime 较新时才会重新编译**。

### 坑 2: TrackType 完全限定名
- 试过 `mozilla::TrackType` ✗
- 试过 `mozilla::media::TrackType` ✗
- 正确：`mozilla::TrackInfo::TrackType`（TrackType 是 TrackInfo 的内嵌 enum）

### 坑 3: 头文件 include 路径
直接 `#include "AnnexB.h"`（无 namespace 前缀）就够了，因为 Mozilla moz.build 已经把 bytestreams 加到 include path。

### 坑 4: MOZ_OBJDIR 路径
要给 `./mach build` 设置 `MOZ_OBJDIR=/绝对路径/.../obj-stream`，否则会在 firefox 源码内创建 `obj-*` 目录。

## 运行时验证

### 7/11 测试（Xvfb headless）
- Xvfb :99 (1920x1080)
- 加载 `file:///tmp/test-stream2.html`
- HTML 内 `<video src="...BigBuckBunny.mp4" autoplay controls muted>`
- 设置 `MOZ_STREAM_DUMP_PATH=/tmp/moz_stream_dumps/...h264`

**结果**: ❌ dump 文件未生成，stderr 0 bytes。怀疑 headless autoplay 被阻止。

### 7/12 重新验证（真实显示器 :1）

实际推断错了。真实显示器 `:1` 上跑后，**确认 hook 点位置错误**：

#### 诊断过程

1. **第一次跑**: hook 只挂在 `OnVideoDemuxCompleted`，stderr 全空，`/tmp/test-dump.h264` 句柄从没打开
2. **加诊断**: 让 `Dump` 入口往 `/tmp/sd-diag.log` 写 call id
   - 结果：日志里 **0 条 StreamDumper 调用** —— hook 完全不触发
3. **加第二个 hook 点**: `HandleDemuxedSamples` 里的 `DecodeDemuxedSamples` 之前
   - 结果：dump 头几个 NALU 出现，但 `!info` early-return —— **aSample->mTrackInfo 是 null**
4. **根因**: MP4Demuxer 的 `GetNextSample()` 从不解码器侧设置 mTrackInfo
   - 只设了 mExtraData 和 mKeyframe（[MP4Demuxer.cpp:407](firefox/dom/media/mp4/MP4Demuxer.cpp#L407)）
   - HLSDemuxer / TrackBuffersManager / MediaChangeMonitor 都设，**唯独 MP4Demuxer 不设**
5. **修复**: StreamDumper 接受可选 `const TrackInfo* aInfo` 参数
   - 调用方传 `decoder.GetCurrentInfo()`（自动 fallback 到 mOriginalInfo）
6. **结果**: ✅ 完整 dump

#### 诊断输出

```
[StreamDumper] Dump call #0 track=2
[StreamDumper] writing H.264 stream to /tmp/moz_stream_dumps/verify-20260712-203606.h264
[StreamDumper] wrote 34 bytes of SPS/PPS header
[StreamDumper] frame=1 time=0us size=23362
[StreamDumper] frame=2 time=40000us size=31957
...
[StreamDumper] frame=500 time=9960000us size=31328
```

**dump 文件**: 16MB, 25fps, 1280x720 H.264 baseline
**ffprobe**: 完全识别（width/height/profile/level/pix_fmt 全部 OK）
**ffmpeg -c copy 转封装**: 成功 913 帧 36.5s mp4（中途截屏），与原测试 mp4 画质一致

#### 双 hook 点

保留两个 hook，覆盖两条路径：
- `OnVideoDemuxCompleted` —— **MSE / EME+CDM 路径**（HLS、ClearKey、Widevine L3）
- `HandleDemuxedSamples` —— **直接 src=MP4 路径**（file://, http(s):// 直链）

后者传 `decoder.GetCurrentInfo()`，绕过 MP4Demuxer 不设 mTrackInfo 的坑。

#### 验证工具

- `scripts/verify-stream.sh` — 启 firefox 加载测试 mp4，每 5s 探测 dump
- `scripts/check-video.py` / `tmp/bidi-full.py` — BiDi WebDriver 查询 video.readyState
- 关键环境变量：`DISPLAY=:1`, `XAUTHORITY=/run/user/1000/gdm/Xauthority`,
  Firefox 启动加 `-remote-allow-origins '*'`，WebSocket 客户端用 `suppress_origin=True`

## 关键产物
- `obj-stream/dist/bin/firefox` (7.1MB)
- `obj-stream/dist/bin/libxul.so` (3.4GB, 16+ 处 StreamDumper 符号)
- `obj-stream/dist/bin/widevine/libwidevinecdm.so` (21MB, 从 Chrome 抠出)
- `patches/0001-dump-stream.patch` (含 StreamDumper 类 + 双 hook 点)
- `scripts/verify-stream.sh` (验证脚本)
- `scripts/check-video.py` + `tmp/bidi-full.py` (BiDi 诊断)

## GitHub
https://github.com/WangYunchao2023/firefox-stream-fetch
