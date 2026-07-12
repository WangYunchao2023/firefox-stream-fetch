#!/bin/bash
# 访问 olevod.com 验证 StreamDumper
set -e

PROJECT="/home/wangyc/Documents/软件类工作/firefox-stream-fetch"
PROFILE="/tmp/firefox-olevod-profile"
DUMP_DIR="/tmp/moz_stream_dumps"
mkdir -p "$DUMP_DIR"

rm -rf "$PROFILE"
mkdir -p "$PROFILE"

cat > "$PROFILE/user.js" << 'PJ'
user_pref("media.autoplay.default", 0);
user_pref("media.autoplay.blocking_policy", 0);
user_pref("media.autoplay.allow-extension-background-events", true);
user_pref("security.sandbox.content.level", 0);
user_pref("security.sandbox.gmp.level", 0);
user_pref("security.sandbox.rdd.level", 0);
user_pref("security.sandbox.socket.level", 0);
user_pref("security.sandbox.utility.level", 0);
user_pref("browser.tabs.unloadOnLowMemory", false);
user_pref("media.suspend-bkgnd-video.enabled", false);
PJ

FF=$(find "$PROJECT/obj-stream" -name "firefox" -type f -executable 2>/dev/null | head -1)
[ -z "$FF" ] && { echo "❌ 找不到 firefox"; exit 1; }
FF_DIR=$(dirname "$FF")
echo "✅ Firefox: $FF"

if [ ! -d "$FF_DIR/widevine" ]; then
    SRC="$PROJECT/firefox-dist/widevine"
    [ -d "$SRC" ] && cp -r "$SRC" "$FF_DIR/widevine" && echo "✅ Widevine 已部署"
fi

DUMP_FILE="$DUMP_DIR/olevod-$(date +%Y%m%d-%H%M%S).h264"
rm -f "$DUMP_FILE"
LOG="$DUMP_DIR/olevod.log"
> "$LOG"

export MOZ_STREAM_DUMP_PATH="$DUMP_FILE"
export MOZ_DISABLE_RDD_SANDBOX=1
export DISPLAY=:1
export XAUTHORITY=/run/user/1000/gdm/Xauthority
export http_proxy=http://127.0.0.1:19090
export https_proxy=http://127.0.0.1:19090

setsid nohup "$FF" \
    -profile "$PROFILE" \
    -no-remote --new-instance \
    -remote-debugging-port 9222 \
    -remote-allow-origins '*' \
    "https://www.olevod.com/player/vod/1-82695-1.html" \
    < /dev/null > "$LOG" 2>&1 &
FF_PID=$!
disown

echo "Firefox PID: $FF_PID"
echo "Dump: $DUMP_FILE"
echo "Log:  $LOG"
echo ""
sleep 10

# 探测循环
for i in 1 2 3 4 5 6 7 8; do
    sleep 5
    if [ -f "$DUMP_FILE" ]; then
        SIZE=$(stat -c%s "$DUMP_FILE")
        echo "[$i] ✅ Dump: $SIZE bytes"
    else
        echo "[$i] ❌ 暂无 dump"
    fi
done

echo ""
echo "=== 最终状态 ==="
echo "Dump: $(ls -la $DUMP_FILE 2>/dev/null || echo '不存在')"
echo ""
echo "--- log 末尾 30 行 ---"
tail -30 "$LOG"
echo ""
echo "--- StreamDumper ---"
grep StreamDumper "$LOG" | head -10
echo "(共 $(grep -c StreamDumper $LOG) 条)"
