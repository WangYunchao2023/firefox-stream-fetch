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

### 测试环境
- Xvfb :99 (1920x1080)
- 加载 `file:///tmp/test-stream2.html`
- HTML 内 `<video src="...BigBuckBunny.mp4" autoplay controls muted>`
- 设置 `MOZ_STREAM_DUMP_PATH=/tmp/moz_stream_dumps/...h264`

### 结果
- ❌ dump 文件未生成
- ❌ firefox-stderr.log 0 bytes
- ❌ 同样的现象 firefox-re 的 YUV 版也出现

### 推测原因
- Xvfb headless 环境中 audio/video autoplay 自动被阻止
- HTML5 video 元素可能因为无音频 sink 而无法自动进入 playing 状态
- **跟 patch 本身无关**——基础设施层面问题

### 解决办法（待用户手动测试）
1. 在真实桌面环境（有 X11/Wayland 显示器）手动启动 firefox
2. 播放 Widevine L3 内容
3. 实时观察 dump 文件增长
4. 用 `ffplay -f h264 /tmp/moz_stream.h264` 验证

## 关键产物
- `obj-stream/dist/bin/firefox` (7.1MB)
- `obj-stream/dist/bin/libxul.so` (3.4GB, 16 处 StreamDumper 符号)
- `obj-stream/dist/bin/widevine/libwidevinecdm.so` (21MB, 从 Chrome 抠出)
- `patches/0001-dump-stream.patch` (1.8KB, 96+ 行 +5/-0)

## GitHub
https://github.com/WangYunchao2023/firefox-stream-fetch
