#!/bin/bash
# verify-capture-integration.sh — 验证 capture-generic.sh + lib-monitor 集成
#
# 不走 CF（手动 Phase 1），直接创建带 fake cf_clearance cookie 的 profile，
# 让 capture-generic.sh 跳过 Phase 1，进入 Phase 2（用 lib-monitor）。
#
# 测试场景：
#   1. 创建 fake profile（含 cf_clearance cookie）
#   2. 跑 ./capture-generic.sh file:///tmp/test-capture-integration.html test-int
#   3. 验证 Phase 2 启动 monitor_run + 写 dump + 转 mp4 + audio 合流
#
# 用法: bash verify-capture-integration.sh
set -e

PROJECT="/home/wangyc/Documents/软件类工作/firefox-stream-fetch"
PROFILE_NAME="test-int"
PROFILE="/tmp/firefox-stream-$PROFILE_NAME"
DUMP_GLOB="/tmp/firefox-stream-$PROFILE_NAME"

echo "=== 准备 ==="
# 清旧
rm -rf "$PROFILE"
mkdir -p "$PROFILE"

# Phase 1 user.js（content prefs — Phase 2 monitor 自己 export dump env）
cat > "$PROFILE/user.js" << 'PJ'
user_pref("media.autoplay.default", 0);
user_pref("media.autoplay.allow-extension-background-events", true);
user_pref("security.sandbox.content.level", 0);
user_pref("security.sandbox.gmp.level", 0);
user_pref("security.sandbox.rdd.level", 0);
user_pref("security.sandbox.socket.level", 0);
user_pref("security.sandbox.utility.level", 0);
PJ

# 起 firefox 一次让 cookie.sqlite 创建，然后塞 fake cf_clearance cookie
echo "  创建 cookies.sqlite + 塞 fake cf_clearance..."

FF=$(find -L "$PROJECT/obj-stream" -path "*dist/bin/firefox" -type f -executable 2>/dev/null | head -1)
[ -z "$FF" ] && { echo "❌ 找不到 firefox"; exit 1; }

export DISPLAY=:1 XAUTHORITY=/run/user/1000/gdm/Xauthority MOZ_ENABLE_WAYLAND=0 GDK_BACKEND=x11
export http_proxy=http://127.0.0.1:19090 https_proxy=http://127.0.0.1:19090
setsid nohup "$FF" -profile "$PROFILE" -no-remote --new-instance "about:blank" \
    < /dev/null > /tmp/profile-init.log 2>&1 &
disown
sleep 5
pkill -f "firefox.*test-int" 2>/dev/null
sleep 2

# 检查 cookies.sqlite 是否生成
COOKIE_DB="$PROFILE/cookies.sqlite"
if [ ! -f "$COOKIE_DB" ]; then
    echo "  ⚠️  cookies.sqlite 不存在，手动创建..."
    sqlite3 "$COOKIE_DB" "CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, name TEXT, value TEXT, host TEXT, expiry INTEGER, path TEXT, creationTime INTEGER, lastAccessedTime INTEGER);"
    sqlite3 "$COOKIE_DB" "CREATE TABLE sqlite_master (type TEXT, name TEXT, tbl_name TEXT, rootpage INTEGER, sql TEXT);"
fi

# 塞 fake cookie（expiry 1 天后）
EXPIRY=$(($(date +%s) + 86400))
sqlite3 "$COOKIE_DB" "INSERT INTO moz_cookies (name, value, host, path, expiry) VALUES ('cf_clearance', 'fake', '.yfsp.tv', '/', $EXPIRY);"

COUNT=$(sqlite3 "$COOKIE_DB" "SELECT COUNT(*) FROM moz_cookies WHERE name='cf_clearance';")
echo "  ✅ cookies.sqlite 有 $COUNT 条 cf_clearance"

echo ""
echo "=== 跑 capture-generic.sh (跳过 Phase 1，直接 Phase 2) ==="

# capture-generic.sh 在 firefox-stream-fetch 目录
cd "$PROJECT"
# 直接用 mp4 URL（绕过 file:// 页面的跨协议问题）
./scripts/capture-generic.sh "http://127.0.0.1:8765/test-video.mp4" "$PROFILE_NAME" \
    --output /tmp/firefox-stream-verify-output \
    --no-cleanup 2>&1 | tee /tmp/capture-integration.log | tail -60

echo ""
echo "=== 验证产出 ==="
ls -lh /tmp/firefox-stream-verify-output/ 2>&1 | head -10

# 找最新 .h264 + .mp4
LATEST_MP4=$(ls -t /tmp/firefox-stream-verify-output/*.mp4 2>/dev/null | head -1)
if [ -n "$LATEST_MP4" ]; then
    echo ""
    echo "  mp4 ffprobe:"
    ffprobe -hide_banner -show_format -show_streams "$LATEST_MP4" 2>&1 \
        | grep -E "codec_name|profile|width|height|duration=|Stream #" | head -10
fi

# 找 sidecar
LATEST_SIDECAR=$(ls -t /tmp/firefox-stream-verify-output/*.sidecar.json 2>/dev/null | head -1)
if [ -n "$LATEST_SIDECAR" ]; then
    echo ""
    echo "  sidecar JSON:"
    jq -C . "$LATEST_SIDECAR" 2>&1 | head -30
fi

# 清理
rm -rf /tmp/firefox-stream-verify-output "$PROFILE" /tmp/test-capture-integration.html 2>/dev/null
echo ""
echo "测试完成"