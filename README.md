# firefox-stream-fetch

在 Firefox **CDM 解密完成后、解码开始前**截获原始视频码流，输出为可重封装的 `.fragment.mp4`。

## 与姊妹项目的关系

| 项目 | hook 点 | 输出格式 | 画质 |
|---|---|---|---|
| [firefox-frame-dump](../firefox-re) | FFmpegVideoDecoder 输出（YUV 像素） | 裸 I420 `.yuv` 文件 | 必须再编码，**有损** |
| **firefox-stream-fetch（本项目）** | MSE+CDM 输出（H.264 码流） | Fragment MP4 序列 | **无损** |

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
- [ ] 定位 hook 点
- [ ] 写 patch
- [ ] 编译 + 测试

## 限制

- 仅对 **L3 软件解密**有效（桌面 Linux 默认）
- 仅对 **H.264/AVC** 内容有效（最常见）；H.265/AV1 需要适配
- 仅供研究/学习，请遵守当地法律
