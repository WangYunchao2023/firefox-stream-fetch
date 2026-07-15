#!/bin/bash
# verify-resume.sh — 自动化验证 firefox 崩溃后能否自动恢复 + 续抓
#
# 测试场景：
#   1. 启动 firefox 加载 HTTP 测试流（10s）
#   2. 跑 monitor_run 监控
#   3. 在 dump 跑到 ~5s 时 kill firefox（模拟崩溃）
#   4. monitor_run 应自动重启 firefox + seek 到断点
#   5. 验证：dump 分两段（part1.h264 + part2.h264）都产出
#   6. ffmpeg concat 合并两段
#
# 用法: bash verify-resume.sh [test_http_port]
set -e

PROJECT="/home/wangyc/Documents/软件类工作/firefox-stream-fetch"
PROFILE="/tmp/firefox-resume-verify-profile"
DUMP_DIR="/tmp/moz_stream_dumps"
HTTP_PORT="${1:-8765}"

rm -rf "$PROFILE"
mkdir -p "$PROFILE" "$DUMP_DIR"

# 起本地 HTTP server（如果还没起）
if ! ss -tln | grep -q ":${HTTP_PORT} "; then
    echo "❌ HTTP server :${HTTP_PORT} 未启，请先跑：cd /tmp && python3 -m http.server $HTTP_PORT &"
    exit 1
fi

cat > "$PROFILE/user.js" << 'PJ'
user_pref("media.autoplay.default", 0);
user_pref("media.autoplay.blocking_policy", 0);
user_pref("media.autoplay.allow-extension-background-events", true);
user_pref("security.sandbox.content.level", 0);
user_pref("security.sandbox.gmp.level", 0);
user_pref("security.sandbox.rdd.level", 0);
user_pref("security.sandbox.socket.level", 0);
user_pref("security.sandbox.utility.level", 0);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.shell.skipDefaultBrowserCheckOnFirstRun", true);
user_pref("browser.aboutwelcome.enabled", false);
PJ

FF=$(find -L "$PROJECT/obj-stream" -path "*dist/bin/firefox" -type f -executable 2>/dev/null | head -1)
FF_DIR=$(dirname "$FF")
echo "✅ Firefox: $FF"

if [ ! -d "$FF_DIR/widevine" ]; then
    SRC="$PROJECT/firefox-dist/widevine"
    [ -d "$SRC" ] && cp -r "$SRC" "$FF_DIR/widevine" && echo "✅ Widevine 部署"
fi

STAMP=$(date +%Y%m%d-%H%M%S)
DUMP_BASE="$DUMP_DIR/resume-verify-$STAMP"
DUMP_VIDEO="$DUMP_BASE.h264"
DUMP_AUDIO="$DUMP_BASE.aac"
SIDECAR="$DUMP_BASE.sidecar.json"
LOG="$DUMP_DIR/resume-verify-firefox-$STAMP.log"
MONITOR_LOG="$DUMP_DIR/resume-verify-monitor-$STAMP.log"

rm -f "$DUMP_VIDEO" "$DUMP_AAC" "$SIDECAR"
: > "$LOG"
: > "$MONITOR_LOG"

echo ""
echo "=== 测试参数 ==="
echo "  Dump base: $DUMP_BASE"
echo "  Sidecar:   $SIDECAR"
echo "  Monitor:   $MONITOR_LOG"
echo ""

# 准备 HTML
cat > /tmp/test-resume.html << HTML
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Resume Test</title></head>
<body>
<video src="http://127.0.0.1:${HTTP_PORT}/test-video.mp4" autoplay controls muted style="width:640px"></video>
<p>resume-verify test</p>
</body></html>
HTML

# env
export DISPLAY=:1
export XAUTHORITY=/run/user/1000/gdm/Xauthority
export MOZ_ENABLE_WAYLAND=0
export GDK_BACKEND=x11
export MOZ_DISABLE_RDD_SANDBOX=1

# === 阶段 1：首次启动（不 resume）===
echo ""
echo "════════════════════════════════════════════════════"
echo "  阶段 1：首次启动 monitor（不 resume）"
echo "════════════════════════════════════════════════════"

source "$PROJECT/scripts/lib-sidecar.sh"
source "$PROJECT/scripts/lib-monitor.sh"

# 把 monitor 的 stderr 重定向到 MONITOR_LOG
export MONITOR_STALL_LIMIT=10          # 5s × 10 = 50s（短点便于测试）
export MONITOR_PAUSED_LIMIT=200
export MONITOR_MAX_INTERRUPTS=3
export MONITOR_INTERVAL=5

# 启动 monitor 后台
monitor_run "$FF" "$PROFILE" "file:///tmp/test-resume.html" \
    "$DUMP_VIDEO" "$DUMP_AUDIO" "$SIDECAR" \
    > "$MONITOR_LOG" 2>&1 &
MONITOR_PID=$!
disown

echo "Monitor PID: $MONITOR_PID"

# 等 dump 开始（约 8s）
echo ""
echo "⏳ 等 dump 开始（最多 15s）..."
for i in $(seq 1 15); do
    sleep 1
    if [ -f "$DUMP_VIDEO" ] && [ "$(stat -c%s "$DUMP_VIDEO" 2>/dev/null)" -gt 1000 ]; then
        SIZE=$(stat -c%s "$DUMP_VIDEO")
        echo "  ✅ 第 ${i}s dump 已开始: $SIZE bytes"
        break
    fi
done

if [ ! -f "$DUMP_VIDEO" ]; then
    echo "❌ dump 没开始"
    kill -9 $MONITOR_PID 2>/dev/null
    pkill -f "firefox.*resume-verify" 2>/dev/null
    exit 1
fi

# === 阶段 2：杀 firefox（模拟崩溃）===
echo ""
echo "════════════════════════════════════════════════════"
echo "  阶段 2：杀 firefox（模拟崩溃）"
echo "════════════════════════════════════════════════════"

# 等 dump 多跑几秒（确保有足够进度）
sleep 8
SIZE_BEFORE_KILL=$(stat -c%s "$DUMP_VIDEO")
CURRENT_TIME_BEFORE=$(jq -r '.current_time' "$SIDECAR" 2>/dev/null || echo "?")
echo "  崩溃前 dump size: $SIZE_BEFORE_KILL bytes, current_time: $CURRENT_TIME_BEFORE s"

# 找 firefox 进程并 kill
FF_PIDS=$(pgrep -f "firefox.*resume-verify-profile" 2>/dev/null || true)
if [ -z "$FF_PIDS" ]; then
    echo "❌ 找不到 firefox 进程"
    kill -9 $MONITOR_PID 2>/dev/null
    exit 1
fi
echo "  💀 Killing firefox PIDs: $FF_PIDS"
kill -9 $FF_PIDS 2>/dev/null || true

# === 阶段 3：等 monitor 自动恢复 ===
echo ""
echo "════════════════════════════════════════════════════"
echo "  阶段 3：等 monitor 检测崩溃 + 自动恢复"
echo "════════════════════════════════════════════════════"

# monitor 检测崩溃后会自动重启 firefox + seek
# 等几秒看恢复
sleep 20

SIZE_AFTER_RESUME=$(stat -c%s "$DUMP_VIDEO" 2>/dev/null || stat -c%s "${DUMP_VIDEO%.h264}.p2.h264" 2>/dev/null || echo 0)
INTERRUPT_COUNT=$(jq -r '.interrupt_count' "$SIDECAR" 2>/dev/null || echo "?")
LAST_KEYFRAME=$(jq -r '.last_keyframe_pts' "$SIDECAR" 2>/dev/null || echo "?")

echo ""
echo "=== 恢复状态 ==="
echo "  interrupt_count: $INTERRUPT_COUNT"
echo "  last_keyframe_pts: $LAST_KEYFRAME s"
echo "  当前 dump 大小: $SIZE_AFTER_RESUME bytes"

# 检查 part 文件
echo ""
echo "=== Dump 文件 ==="
ls -la "${DUMP_VIDEO%.h264}".p*.h264 2>/dev/null | sed 's/^/  /'

# === 阶段 4：让 monitor 跑完（stall 后结束）===
echo ""
echo "════════════════════════════════════════════════════"
echo "  阶段 4：等 monitor 跑完（stall_limit 或 video.ended）"
echo "════════════════════════════════════════════════════"

# 给 monitor 足够时间结束（stall_limit 50s + 缓冲）
sleep 60

# 关 monitor（如果还在）
kill -9 $MONITOR_PID 2>/dev/null || true
pkill -f "firefox.*resume-verify" 2>/dev/null || true

# === 最终验证 ===
echo ""
echo "════════════════════════════════════════════════════"
echo "  最终验证"
echo "════════════════════════════════════════════════════"

echo ""
echo "--- 所有 .h264 分段 ---"
ls -la "${DUMP_VIDEO%.h264}".p*.h264 2>/dev/null
echo ""
echo "--- 所有 .aac 分段 ---"
ls -la "${DUMP_VIDEO%.h264}".p*.aac 2>/dev/null
echo ""
echo "--- Sidecar JSON ---"
jq -C . "$SIDECAR" 2>/dev/null | head -40

# 检查：至少应该有 p1.h264 和 p2.h264 两段
PART_COUNT=$(ls "${DUMP_VIDEO%.h264}".p*.h264 2>/dev/null | wc -l)
if [ "$PART_COUNT" -ge 2 ]; then
    echo ""
    echo "✅ SUCCESS: dump 分成 $PART_COUNT 段（firefox 崩溃后自动恢复成功）"
else
    echo ""
    echo "⚠️  WARNING: 只找到 $PART_COUNT 段（预期 ≥ 2）"
fi

# 检查 sidecar 的 interrupt_count
INTERRUPT=$(jq -r '.interrupt_count' "$SIDECAR")
if [ "$INTERRUPT" -ge 1 ]; then
    echo "✅ sidecar 记录了 $INTERRUPT 次中断"
else
    echo "❌ sidecar 没记录中断（监控没检测到崩溃？）"
fi

# === 阶段 5：ffmpeg concat 合并 ===
echo ""
echo "════════════════════════════════════════════════════"
echo "  阶段 5：ffmpeg concat 合并分段"
echo "════════════════════════════════════════════════════"

# 准备 concat list
CONCAT_LIST="$DUMP_BASE.concat.txt"
PARTS=$(ls "${DUMP_VIDEO%.h264}".p*.h264 2>/dev/null | sort)
if [ -n "$PARTS" ]; then
    > "$CONCAT_LIST"
    for p in $PARTS; do
        echo "file '$p'" >> "$CONCAT_LIST"
    done
    echo "--- concat list ---"
    cat "$CONCAT_LIST"
    echo ""

    MERGED="$DUMP_BASE.merged.mp4"
    # 需要 audio 也合并 — 暂时只 concat 视频验证分段恢复
    echo "--- ffmpeg concat (仅视频，验证分段可拼接) ---"
    if ffmpeg -y -f concat -safe 0 -i "$CONCAT_LIST" -c copy "$MERGED" 2>&1 | tail -3; then
        echo ""
        echo "--- 合流 ffprobe ---"
        ffprobe -hide_banner "$MERGED" 2>&1 | head -10
    fi
fi

# 清理
rm -rf "$PROFILE" /tmp/test-resume.html 2>/dev/null
echo ""
echo "测试完成"