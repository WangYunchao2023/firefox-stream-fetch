# firefox-stream-fetch 接口文档

> 记录各组件间的接口协议、数据格式、调用约定。
> 最后更新：2026-07-30（v3.2）

---

## 1. Firefox Patch 接口（C++ 内部）

### 1.1 StreamDumper::Dump()

**位置：** `firefox/dom/media/MediaFormatReader.cpp`

**调用方：** 两处

#### 调用点 1 — OnVideoDemuxCompleted

```cpp
// 位于 MediaFormatReader::OnVideoDemuxCompleted() 内
for (const auto& sample : aSamples->GetSamples()) {
    StreamDumper::Dump(TrackInfo::kVideoTrack, sample);
}
```

- `aTrack`: 固定 `kVideoTrack`
- `aSample`: 解复用后的 MediaRawData*
- `aInfo`: 未传入（nullptr），依赖 sample->mTrackInfo（HLS demuxer 设了）

#### 调用点 2 — HandleDemuxedSamples

```cpp
// 位于 MediaFormatReader::HandleDemuxedSamples() 内，DecodeDemuxedSamples 之前
StreamDumper::Dump(aTrack, sample, decoder.GetCurrentInfo());
```

- `aTrack`: 来自调用参数（kVideoTrack / kAudioTrack）
- `aSample`: 解复用后的 MediaRawData*
- `aInfo`: `decoder.GetCurrentInfo()`（可靠来源）

### 1.2 StreamDumper::DumpAudio()

**位置：** `firefox/dom/media/MediaFormatReader.cpp`，`StreamDumper::Dump()` 内部

```cpp
static void DumpAudio(MediaRawData* aSample, const TrackInfo* aInfo);
```

- 自动计算音频 dump 路径（去视频扩展名 + .aac）
- 使用 Mozilla 内置 `ADTS::ConvertSample()` 包装 AAC
- 输出到全局 `gAudioDumpFile`（非函数局部 static）

### 1.3 PTSDumpLogger（v4.0.0 新增 · v4.1 分文件）

**位置：** `firefox/dom/media/MediaFormatReader.cpp`，匿名命名空间内

```cpp
class PTSDumpLogger {
 private:
  static void SplitPaths(const char* basePath, char (&videoPath)[512],
                         char (&audioPath)[512]);
 public:
  static void Log(TrackType aTrack, const MediaRawData* aSample);
};
```

**调用时机：** `StreamDumper::Dump()` 入口 — **warmup skip 之前**、codec dispatch 之前。
每帧都经过此处，因此所有帧（含预热丢弃帧）的 PTS 都会被记录，并路由到对应 track 的文件。

**触发方式：**
- **默认**：`capture.sh` 自动导出 `$PTS_FILE`（如 `$OUTPUT_DIR/pts_<name>.pts`），实际生成两个文件：
  - `<base>.pts` → **视频 PTS**（仅视频帧）
  - `<base>_audio.pts` → **音频 PTS**（仅音频帧）
- **手动**：设置环境变量 `MOZ_STREAM_DUMP_PTS_FILE=/自定义路径/dump.pts`，同样生成两个分文件
- 未设置 → 零开销（仅一次 getenv + branch 判断）
- 已设置 → lazy open：首次遇到某 track 类型时打开对应文件（行缓冲）

**输出格式（纯文本 TSV，每文件独立）：**

| 列 | 类型 | 说明 |
|---|---|---|
| pts_us | uint64 | mTime.ToMicroseconds()，demuxer 输出的原始 PTS |
| duration_us | uint64 | mDuration.ToMicroseconds()（IsPositive 时才非零） |
| size | uint32 | aSample->Size() |
| keyframe | int32 | mKeyframe.value_or(false) ? 1 : 0 |
| offset | int64 | aSample->mOffset |

> **v4.1 变更**：track_type 列已移除——文件名本身就说明了 track 类型。解析更简单：read `.pts` 就是视频，读 `_audio.pts` 就是音频。

**示例输出：**

视频文件 `pts_video.pts`：
```
# pts_us	 duration_us	 size	 keyframe	 offset
0	33333	12345	1	0
33333	33333	8765	0	12345
```

音频文件 `pts_audio.pts`：
```
# pts_us	 duration_us	 size	 keyframe	 offset
23229	23229	8192	0	0
46458	23229	4096	0	8192
```

### 1.4 环境变量接口

| 变量 | 读/写 | 说明 |
|---|---|---|
| `MOZ_STREAM_DUMP_PATH` | 读 | dump 输出路径；空值或未设则用默认 |
| `MOZ_STREAM_DUMP_PTS_FILE` | 读（v4.1） | PTS dump 基础路径；设置后自动生成视频+音频两个 `.pts` 文件，空值或未设则禁用 |

**注意：** capture.sh Phase 1 设为 `/dev/null`，Phase 2 设为实际路径。

---

## 2. SDFV/SDFA Dump 文件格式

### 2.1 视频 (SDFV) v1

```
Offset  Size  内容
0       4     magic "SDFV"
4       1     version (1)
5       3     reserved (0)
8       4     header_len (LE uint32)
12      N     header_data (SPS/PPS 等，N = header_len bytes)
12+N    4     frame_size (LE uint32)
16+N    8     pts_us (LE uint64)
24+N    M     frame_data (M = frame_size bytes)
...     ...   下一帧（同样结构）
```

**示例十六进制（头部 + 首帧）：**
```
SDFV 01 00 00 00  0018 0000  ← "SDFV" + v1 + header_len=24
[24 bytes SPS/PPS]
[4 bytes NALU size] [8 bytes PTS] [NALU data]
...
```

### 2.2 音频 (SDFA) v1

```
Offset  Size  内容
0       4     magic "SDFA"
4       1     version (1)
5       3     reserved (0)
8       4     frame_size (LE uint32)
12      8     pts_us (LE uint64)
20      M     frame_data (ADTS frame, M = frame_size bytes)
...     ...   下一帧
```

**注意：** SDFA 无 header_len 字段（音频不需要 SPS 等 extra data）。

### 2.3 PTS 格式

- 单位：微秒（us）
- 来源：`aSample->mTime.ToMicroseconds()`（Firefox 内部时间）
- 可能不可信：MSE 路径下 Firefox 的 mTime 可能与实际播放不同步
  - 检测方式：PTS span < n_frames/30s 即认为不可信
  - 修复：用音频时长推算帧间隔（以音频为时钟源）

---

## 3. BiDi 守护协议

### 3.1 通信拓扑

```
┌──────────────┐    TCP 9222     ┌──────────────────┐    unix socket   ┌──────────────┐
│ Firefox      │ ◄─────────────► │ bidi-state.py     │ ◄──────────────► │ lib-monitor  │
│ BiDi Server  │   WebSocket     │ daemon (TCP)      │   stdin/stdout │              │
│ (port 9222)  │                 │                   │   (JSON)       │              │
└──────────────┘                 └──────────────────┘                 └──────────────┘
```

### 3.2 命令/响应协议

**格式：** 一行一条 JSON，通过 unix socket 的 stdin/stdout 传输。

#### query — 查询 video 状态

**请求：**
```json
{
  "cmd": "query",
  "url_pattern": ".*"
}
```

**响应（正常）：**
```json
{
  "state": "playing",
  "paused": false,
  "ended": false,
  "currentTime": 123.45,
  "duration": 1800.0,
  "readyState": 4,
  "networkState": 1,
  "bufferedEnd": 120.0,
  "src": "https://example.com/video.m3u8",
  "error": 0,
  "errorMsg": "",
  "videoWidth": 1920,
  "videoHeight": 1080,
  "visibility": "visible",
  "url": "https://example.com/watch?v=xxx",
  "next_episode_url": null
}
```

**响应（no-video）：**
```json
{
  "state": "no-video",
  "url": "https://example.com/watch?v=xxx",
  "visibility": "visible"
}
```

**响应（error）：**
```json
{
  "err": "...",
  "hint": "..."
}
```

**state 值及含义：**

| state | 含义 | monitor 动作 |
|---|---|---|
| `playing` | 视频正在播放 | stall 计数归零 |
| `paused` | 用户暂停 | 不增 stall |
| `buffering` | 缓冲中 | stall 减半 |
| `ended` | 播放结束 | 立即结束 |
| `no-video` | 无可检测的 video 元素 | 触发恢复 |
| `next_episode` | 下一集切换 | 写 sidecar 并循环 |
| `unknown` | 无法判断 | stall 正常累计 |

#### seek — 跳转到指定位置

**请求：**
```json
{"cmd": "seek", "seconds": 120.5}
```

**响应：**
```json
{"ok": true, "newTime": 120.5}
```

#### stop — 停止 daemon

**请求：**
```json
{}
```
或
```json
{"cmd": "stop"}
```

#### ping — 存活检查

**请求：**
```json
{"cmd": "ping"}
```

**响应：**
```json
{"ok": true}
```

---

## 4. Sidecar JSON 格式

**路径：** `${DUMP_FILE}.sidecar.json`

**结构：**
```json
{
  "version": 1,
  "started_at": "2026-07-30T14:00:00.000Z",
  "last_updated": "2026-07-30T14:30:00.000Z",
  "url": "https://example.com/watch?v=xxx",
  "dump_video": "/tmp/xxx.h264",
  "dump_audio": "/tmp/xxx.aac",
  "video_state": "playing",
  "current_time": 123.45,
  "duration": 1800.0,
  "ready_state": 4,
  "buffered_end": 120.0,
  "last_dump_size_video": 1048576,
  "last_dump_size_audio": 2048,
  "last_keyframe_pts": 123456000,
  "interrupt_count": 0,
  "interrupt_reasons": [],
  "parts": [
    {"file": "/tmp/xxx-01.h264", "start": 0, "end": 300.5}
  ],
  "last_ff_url": "https://example.com/watch?v=xxx",
  "ended_at": null,
  "end_reason": null,
  "next_episode_url": null,
  "episode_index": 1
}
```

**关键字段说明：**

| 字段 | 写入时机 | 用途 |
|---|---|---|
| `last_keyframe_pts` | 每轮监控结束时 | 崩溃恢复时 seek 到该 PTS |
| `last_dump_size_*` | 每轮监控结束时 | 判断 dump 是否在增长（stall 检测） |
| `parts[]` | 每集结束时 | 记录分段文件（ffmpeg concat 用） |
| `next_episode_url` | 切集检测触发 | 传给 capture.sh 继续抓取下一集 |
| `interrupt_reasons[]` | 每次崩溃恢复 | 调试用 |

---

## 5. Shell 脚本接口

### 5.1 capture.sh

**入口：** `scripts/capture.sh [URL] [OPTIONS]`

**选项：**

| 选项 | 说明 |
|---|---|
| `[URL]` | 可选，不填则 Phase 1 开 about:newtab |
| `--output DIR` | 保存目录（默认 `~/Videos/firefox抓取/`） |
| `--auto-next [N]` | 自动连集；带 N → 共抓满 N 集（含起始集）后自动终止，不带 N → 抓到最后一集 |
| `--skip-phase1` | 跳过 Phase 1 |
| `--keep-h264` | 保留 .h264/.aac 中间文件 |
| `--profile PATH` | 指定 profile 路径 |

**输出文件：**

| 文件 | 说明 |
|---|---|
| `<host>-<timestamp>.mp4` | 最终视频 |
| `<host>-<timestamp>.log` | Firefox stdout/stderr + StreamDumper 帧日志 |
| `<host>-<timestamp>.sidecar.json` | Phase 2 状态 |

**内部变量（source 后可用）：**

| 变量 | 说明 |
|---|---|
| `FF` | patched Firefox 二进制路径 |
| `FF_DIR` | Firefox 二进制所在目录 |
| `PROFILE` | profile 路径 |
| `OUTPUT_DIR` | 输出目录 |
| `AUTO_NEXT` | 自动连集标志 |
| `MAX_EPISODES` | 集数上限（0 = 不限；v4.4.0 由 `--auto-next N` 指定） |

### 5.2 lib-sidecar.sh

**来源：** `source "$SCRIPT_DIR/lib-sidecar.sh"`

**函数：**

| 函数 | 签名 | 说明 |
|---|---|---|
| `sidecar_init` | `<sidecar_path>` | 初始化 sidecar JSON |
| `sidecar_get` | `<path> <jq_filter>` | 读字段 |
| `sidecar_set` | `<path> <key> <json_value>` | 写字段（value 需为合法 JSON） |
| `sidecar_add_part` | `<path> <file> <start> <end>` | 添加分段 |
| `sidecar_log_interrupt` | `<path> <reason>` | 记录中断 |
| `sidecar_mark_ended` | `<path> [reason]` | 标记结束 |

**注意：** `sidecar_set` 的 value 参数必须是合法 JSON 值（字符串需带引号）。

### 5.3 lib-monitor.sh

**来源：** 需先 `source lib-sidecar.sh` 再 `source lib-monitor.sh`

**入口：** `monitor_run "$FF_BIN" "$PROFILE" "$URL" "$DUMP_VIDEO" "$DUMP_AUDIO" "$SIDECAR"`

**可调环境变量：**

| 变量 | 默认 | 说明 |
|---|---|---|
| `MONITOR_STALL_LIMIT` | 36 | stall 累计阈值 |
| `MONITOR_PAUSED_LIMIT` | 360 | 最大暂停轮数 |
| `MONITOR_MAX_INTERRUPTS` | 3 | 最大崩溃恢复次数 |
| `MONITOR_BIDI_PORT` | 9222 | BiDi TCP 端口 |
| `MONITOR_INTERVAL` | 5 | 轮询间隔 (s) |
| `MONITOR_DEBUG` | 0 | 开启调试日志 |

---

## 6. Python 脚本接口

### 6.1 sdfv_extract.py

```bash
sdfv_extract.py <dump_file> [--last-pts-only]
```

**输入：** SDFV 或 SDFA dump 文件

**输出：**
- 标准输出：解析到的 frame count
- 同目录生成：`<basename>.raw` + `<basename>.pts`

**`--last-pts-only`：** 仅输出最后一帧 PTS（微秒），不写 .raw/.pts 文件。

### 6.2 mux_with_pts.py

```bash
mux_with_pts.py <prefix> <kind> [--rebase-at-first-keyframe] [--first-keyframe-idx N]
```

**参数：**
- `<prefix>` — `sdfv_extract.py` 输出的 .raw/.pts 前缀
- `<kind>` — `video` 或 `audio`

**输出：**
- `<prefix>.mp4`（视频）
- `<prefix>.m4a`（音频）

---

## 7. Patch 应用接口

### 7.1 如何应用 patch

```bash
cd firefox/
# 先 apply 旧 patch（按版本号升序）
patch -p1 < ../patches/0001-dump-stream.patch
patch -p1 < ../patches/0002-add-av1-support.patch
patch -p1 < ../patches/0003-codec-aware-output.patch
patch -p1 < ../patches/0004-add-audio-dump.patch
patch -p1 < ../patches/0005-stream-source-tracking.patch
# 编译
./mach build
```

### 7.2 只修改 StreamDumper 后重新编译

由于 Mozilla 的 unified build 机制，只改 `.cpp` 的 mtime 比统一编译快很多：

```bash
cd firefox/
touch dom/media/MediaFormatReader.cpp
./mach build --component dom/media
```

**注意：** 如果修改涉及头文件或 nsTArray 等跨文件依赖，需要完整编译。
