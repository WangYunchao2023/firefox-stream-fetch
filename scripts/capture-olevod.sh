#!/bin/bash
# 复测 olevod.com，确认 StreamDumper 端到端仍然可用
set -e

PROJECT="/home/wangyc/Documents/软件类工作/firefox-stream-fetch"
PROFILE="/tmp/firefox-olevod-persistent-profile"
DUMP_DIR="/tmp/moz_stream_dumps"
mkdir -p "$DUMP_DIR"

if [ ! -d "$PROFILE" ]; then
    mkdir -p "$PROFILE"
    cat > "$PROFILE/user.js" << 'PJ'
user_pref("media.autoplay.default", 0);
user_pref("media.autoplay.blocking_policy", 0);
user_pref("media.autoplay.allow-extension-background-events", true);
user_pref("media.suspend-bkgnd-video.enabled", false);
user_pref("security.sandbox.content.level", 0);
user_pref("security.sandbox.gmp.level", 0);
user_pref("security.sandbox.rdd.level", 0);
user_pref("security.sandbox.socket.level", 0);
user_pref("security.sandbox.utility.level", 0);
PJ
fi

FF=$(find "$PROJECT/obj-stream" -name "firefox" -type f -executable 2>/dev/null | head -1)
FF_DIR=$(dirname "$FF")

if [ ! -d "$FF_DIR/widevine" ]; then
    SRC="$PROJECT/firefox-dist/widevine"
    [ -d "$SRC" ] && cp -r "$SRC" "$FF_DIR/widevine"
fi

DUMP_FILE="$DUMP_DIR/olevod-$(date +%Y%m%d-%H%M%S).h264"
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
    "https://www.olevod.com/player/vod/1-" \
    < /dev/null > "$LOG" 2>&1 &
FF_PID=$!
disown

echo "Firefox PID: $FF_PID"
echo "Dump: $DUMP_FILE"
echo "Log: $LOG"
echo ""

LAST_SIZE=0
while true; do
    sleep 15
    if ! kill -0 $FF_PID 2>/dev/null; then
        echo "[$(date +%H:%M:%S)] Firefox 已退出"
        break
    fi
    if [ -f "$DUMP_FILE" ]; then
        SIZE=$(stat -c%s "$DUMP_FILE")
        echo "[$(date +%H:%M:%S)] ✅ Dump: $(numfmt --to=iec $SIZE)  (+$((SIZE-LAST_SIZE)))"
        LAST_SIZE=$SIZE
    else
        echo "[$(date +%H:%M:%S)] ⏳ 暂无 dump"
    fi
done

echo ""
echo "=== 最终结果 ==="
if [ -f "$DUMP_FILE" ] && [ "$(stat -c%s "$DUMP_FILE")" -gt 0 ]; then
    echo "✅ Dump: $(ls -lh $DUMP_FILE)"
    echo "Frames: $(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$DUMP_FILE" 2>/dev/null || echo 'N/A')"
    echo "Duration: $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$DUMP_FILE" 2>/dev/null || echo 'N/A')s"
    echo "Codec: $(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$DUMP_FILE" 2>/dev/null || echo 'N/A')"
else
    echo "❌ 无 dump"
    grep StreamDumper "$LOG" | tail -5 || echo "(无 StreamDumper 日志)"
fi
