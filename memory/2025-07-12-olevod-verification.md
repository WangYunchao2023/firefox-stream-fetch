# 2025-07-12 olevod.com 真实流验证

## 验证结果：✅ 完全成功

- **目标**: https://www.olevod.com/player/vod/1-82695-1.html
- **代理**: 极光VPN (127.0.0.1:19090)
- **抓取结果**: H.264 High Profile, 1280x720, level 3.1
- **Dump**: olevod-20260712-213657.h264 (18MB 并持续增长)
- **Remux mp4**: 2232帧, 89秒, 21MB, ffmpeg -c copy 无损

## 帧内容验证

| 帧# | 时间 | 内容 |
|-----|------|------|
| f0001 | 1s | 黑屏（开场） |
| f0030 | 30s | 倒计时数字"3" |
| f0090 | 90s | 钢琴调音教程（真实视频内容），中英字幕 |

## 技术发现

- 两个 track: track=1（可能是音视频描述轨）+ track=2（主视频轨）
- Widevine L3 未触发（网站可能用其他 DRM 或明文流）
- HEVC codec dispatch 框架已编译，但该视频是 H.264
