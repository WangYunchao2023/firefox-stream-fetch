#!/bin/bash
# verify-capture-resume.sh — capture-generic.sh 内 Phase 2 崩溃恢复端到端验证
#
# 与 verify-capture-integration 类似，但跑期间杀 firefox 验证 lib-monitor 自动恢复
set -e

PROJECT="/home/wangyc/Documents/软件类工作/firefox-stream-fetch"
PROFILE_NAME="test-resume"
PROFILE="/tmp/firefox-stream-$PROFILE_NAME"
OUT="/tmp/firefox-stream-verify-output"
mkdir -p "$OUT"

echo "=== 准备 ==="
rm -rf "$PROFILE" "$OUT"/*
mkdir -p "$PROFILE"

# cookies.sqlite + fake cf_clearance
cat > "$PROFILE/user.js" << 'PJ'
user_pref("media.autoplay.default", 0);
user_pref("media.autoplay.allow-extension-background-events", true);
user_pref("security.sandbox.content.level", 0);
user_pref("security.sandbox.gmp.level", 0);
user_pref("security.sandbox.rdd.level", 0);
user_pref("security.sandbox.socket.level", 0);
user_pref("security.sandbox.utility.level", 0);
PJ

FF=$(find -L "$PROJECT/obj-stream" -path "*dist/bin/firefox" -type f -executable 2>/dev/null | head -1)
[ -z "$FF" ] && { echo "❌ 找不到 firefox"; exit 1; }

export DISPLAY=:1 XAUTHORITY=/run/user/1000/gdm/Xauthority MOZ_ENABLE_WAYLAND=0 GDK_BACKEND=x11
setsid nohup "$FF" -profile "$PROFILE" -no-remote --new-instance "about:blank" \
    < /dev/null > /tmp/profile-init.log 2>&1 &
disown
sleep 5
pkill -f "firefox.*test-resume" 2>/dev/null
sleep 2

COOKIE_DB="$PROFILE/cookies.sqlite"
if [ ! -f "$COOKIE_DB" ]; then
    sqlite3 "$COOKIE_DB" "CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, name TEXT, value TEXT, host TEXT, expiry INTEGER, path TEXT);"
fi
EXPIRY=$(($(date +%s) + 86400))
sqlite3 "$COOKIE_DB" "INSERT INTO moz_cookies (name, value, host, path, expiry) VALUES ('cf_clearance', 'fake', '.yfsp.tv', '/', $EXPIRY);"
echo "  ✅ cookies.sqlite ready"

echo ""
echo "=== 跑 capture-generic.sh + 中途 kill firefox ==="
# 为了有足够时间 kill firefox，需要播放时间稍长的视频（生成 30s 测试）
if [ ! -f /tmp/test-video-30s.mp4 ]; then
    ffmpeg -y -f lavfi -i "testsrc=duration=30:size=320x240:rate=25" \
        -f lavfi -i "sine=frequency=440:duration=30" \
        -c:v libx264 -preset ultrafast -profile:v baseline -pix_fmt yuv420p \
        -c:a aac -b:a 128k -shortest /tmp/test-video-30s.mp4 2>&1 | tail -2
fi
cp /tmp/test-video-30s.mp4 /tmp/test-video.mp4 2>/dev/null || true
cp /tmp/test-video-30s.mp4 /tmp/ 2>/dev/null || true  # 确保 http server 能找到（覆盖原 10s 文件）

cd "$PROJECT"
./scripts/capture-generic.sh "http://127.0.0.1:8765/test-video.mp4" "$PROFILE_NAME" \
    --output "$OUT" --no-cleanup > /tmp/capture-resume.log 2>&1 &
CAPTURE_PID=$!
disown

# 等 dump 出现
echo "  等 dump 出现..."
for i in $(seq 1 20); do
    sleep 1
    HIT=$(ls "$OUT"/$PROFILE_NAME-*.h264 2>/dev/null | head -1)
    if [ -n "$HIT" ] && [ "$(stat -c%s "$HIT" 2>/dev/null || echo 0)" -gt 1000 ]; then
        echo "  ✅ 第 ${i}s dump 已开始 ($(stat -c%s "$HIT") bytes)"
        break
    fi
done

# 等 dump 多跑几秒，确保 seek 有目标点
sleep 6

# 杀 firefox（先杀可能多个进程）
FF_PIDS=$(pgrep -f "firefox.*test-resume\|firefox.*firefox-stream-$PROFILE_NAME" 2>/dev/null | tr '\n' ' ')
echo "  💀 Killing firefox PIDs: $FF_PIDS"
kill -9 $FF_PIDS 2>/dev/null
# 也杀子进程（remoteagent 等）
pkill -9 -f "firefox.*$PROFILE_NAME" 2>/dev/null

# 等 capture-generic 恢复 + 完成
echo "  等 monitor 自动恢复 + 完成..."
wait $CAPTURE_PID 2>/dev/null || true
sleep 2

echo ""
echo "=== 验证产出 ==="
ls -la "$OUT" 2>&1

LATEST_MP4=$(ls -t "$OUT"/*.mp4 2>/dev/null | head -1)
if [ -n "$LATEST_MP4" ]; then
    echo ""
    echo "--- mp4 ffprobe ---"
    ffprobe -hide_banner "$LATEST_MP4" 2>&1 | grep -E "Stream|Duration"
fi

LATEST_SIDECAR=$(ls -t "$OUT"/*.sidecar.json 2>/dev/null | head -1)
if [ -n "$LATEST_SIDECAR" ]; then
    echo ""
    echo "--- sidecar 关键字段 ---"
    jq -r '"interrupt_count=\(.interrupt_count) interrupt_reasons=\(.interrupt_reasons) parts=\(.parts | length) end_reason=\(.end_reason)"' "$LATEST_SIDECAR"
fi

# 清理（保留 .h264/.aac 用于分析）
rm -rf "$PROFILE" 2>/dev/null
echo ""
echo "测试完成"