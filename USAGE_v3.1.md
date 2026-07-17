# v3.1 统一抓取脚本 — 快速使用指南

## 核心变化 (v3.0 → v3.1)
- **原 4 个脚本合并为 1 个**：`scripts/capture.sh`（其余 3 个是 1 行 shim，保持兼容）
- **Phase 1 + Phase 2 两阶段架构保留**，统一逻辑
- **代理**：统一读 `http_proxy / https_proxy / all_proxy` 环境变量，无则直联
- **输出目录**：默认 `~/Videos/firefox抓取/`
- **v3.1 新增**：`--auto-next` 正式可用：playlist 自动连集，每集独立 mp4（`host-01.mp4`, `host-02.mp4`...）

---

## 1. 先确认已编译好的 Firefox
```bash
ls /home/wangyc/Documents/软件类工作/firefox-stream-fetch/firefox/obj-x86_64-pc-linux-gnu/dist/bin/firefox
# 存在即可，不存在需先 ./mach build（README 已验证通过）
```

---

## 2. 最快验证（明文流，无 CF，无代理）
```bash
cd /home/wangyc/Documents/软件类工作/firefox-stream-fetch/scripts

# 单集（默认）
./capture.sh "https://www.olevod.com/player/vod/1-82695-1.html"
```
流程：
1. Phase 1 开浏览器（标题含 "Just a moment..." → 过验证；否则直接视为加载完成）
2. 窗口标题变成视频标题 → 自动关闭 Phase 1，进 Phase 2
3. Phase 2 同 profile 重启 Firefox（sandbox 关闭），从头加载、抓 h264 + aac
4. `<video>.ended` 触发 → ffmpeg 合流 → `~/Videos/firefox抓取/olevod.com-<timestamp>.mp4`

---

## 3. 自动连集（v3.1 新增）
```bash
# 加上 --auto-next，每集独立 mp4：host-01.mp4, host-02.mp4...
./capture.sh "https://example.com/playlist" --auto-next
```
行为：
- 当前集播完 → monitor 检测到 `location.href` + `video.currentSrc` 双变化 + `readyState >= 2`
- 写 sidecar `next_url` + `episode_index` → capture.sh 循环读取 → Phase 2 重跑
- 每集产出独立 mp4：`host-01.mp4`, `host-02.mp4`, `host-03.mp4`...
- 无下一集 / 用户未加 `--auto-next` → 单集正常结束

---

## 4. 需要代理的站（YouTube / 国外站）
```bash
# 设置系统代理（任意一种）
export http_proxy=socks5://127.0.0.1:1080
export https_proxy=socks5://127.0.0.1:1080
# 或
export all_proxy=socks5://127.0.0.1:1080

./capture.sh "https://www.youtube.com/watch?v=_n4SRDYkhqs"
# 或带自动连集
./capture.sh "https://www.youtube.com/playlist?list=PLxxx" --auto-next
```
> 脚本 **Phase 1 显式 unset 代理**（避免 CF 抓 proxy 痕迹），Phase 2 自动恢复环境变量。

---

## 5. 需要 CF 验证的站（yfsp.tv 等）
```bash
# 单集
./capture.sh "https://www.yfsp.tv/watch?v=ztgsSWh5mPZEhhazLjYUG6"

# 连集
./capture.sh "https://www.yfsp.tv/playlist/xxx" --auto-next
```
- Phase 1：打开页面，**你手动点过 CF 验证**
- 标题从 "Just a moment..." 变成视频标题 → 自动切 Phase 2
- Phase 2：复用 cookie，sandbox 关闭，直接从头抓

---

## 6. 手动输入 URL（不在命令行传）
```bash
./capture.sh
```
- Phase 1 开 about:newtab，**你在 Firefox 地址栏手输 URL、过验证、播放**
- 检测到标题变化 → 自动进 Phase 2

---

## 7. 常用参数
| 参数 | 作用 |
|---|---|
| `--output DIR` | 改输出目录（默认 `~/Videos/firefox抓取/`） |
| `--auto-next` | **v3.1 正式可用**：playlist 自动连集，每集独立 mp4（`host-01.mp4`, `host-02.mp4`...） |
| `--keep-h264` | 保留 `.h264/.aac` 中间文件（默认合流后删） |
| `--skip-phase1` | 跳过 Phase 1（profile 已有 cf_clearance 时等价） |
| `--profile PATH` | 自定义 profile 路径（默认按 host 自动命名） |

---

## 8. 查看结果
```bash
ls -lh ~/Videos/firefox抓取/
ffplay ~/Videos/firefox抓取/olevod.com-01.mp4
```

---

## 9. 兼容旧脚本名（透传参数）
```bash
./capture-olevod.sh "https://www.olevod.com/player/vod/1-82695-1.html"
./capture-yfsp.sh   "https://www.yfsp.tv/watch?v=xxx"
./capture-youtube.sh "https://www.youtube.com/watch?v=xxx"
# 等同于直接跑 ./capture.sh
```

---

## 10. 关键点
- **两阶段都用同一 patched Firefox**，不是两套 binary
- **profile 复用**：Phase 1 写 cookie → Phase 2 同 profile 读 cookie → cf_clearance 复用
- **Sandbox**：Phase 1 开（过 CF），Phase 2 关（让 StreamDumper 写 `/tmp`）
- **监控**：lib-monitor.sh（BiDi + 5s 轮询 `video.ended / stalled / paused / no-video + next_episode`），崩溃自动恢复 ≤ 3 次（seek 到关键帧续接）
- **切集检测**：`location.href` 变化 + `video.currentSrc` 变化 + `readyState >= 2` 三重确认，避免误触发

---

## 11. 如果卡住 / 报错
```bash
# 看 monitor 日志
cat ~/Videos/firefox抓取/olevod.com-<timestamp>.monitor.log
# 看 Firefox stdout/stderr
cat ~/Videos/firefox抓取/olevod.com-<timestamp>.log
# 看 sidecar 状态
cat ~/Videos/firefox抓取/olevod.com-<timestamp>.sidecar.json
```
常见：
- Phase 1 30 分钟超时 → `PHASE1_TIMEOUT` 可在脚本改
- Phase 2 120s 无 dump 增长 → stall_limit 兜底结束（长视频可改 `MONITOR_STALL_LIMIT`）
- 没 dump → 确认视频真在播放（`<video>` 没被广告覆盖 / 暂停）