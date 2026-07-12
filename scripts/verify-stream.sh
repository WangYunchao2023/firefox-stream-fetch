#!/bin/bash
# 验证 stream-dumper v4: 完整 BiDi 查询 + 多轮探测
set -e

PROJECT="/home/wangyc/Documents/软件类工作/firefox-stream-fetch"
PROFILE="/tmp/firefox-stream-verify-profile"
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
user_pref("media.video_stats.enabled", false);
PJ

FF=$(find "$PROJECT/obj-stream" -name "firefox" -type f -executable 2>/dev/null | head -1)
[ -z "$FF" ] && FF=$(find "$PROJECT/obj-stream" -name "firefox-bin" -type f -executable 2>/dev/null | head -1)
[ -z "$FF" ] && { echo "❌ 找不到 firefox 二进制"; exit 1; }
FF_DIR=$(dirname "$FF")
echo "✅ Firefox: $FF"

if [ ! -d "$FF_DIR/widevine" ]; then
    SRC="$PROJECT/firefox-dist/widevine"
    [ -d "$SRC" ] && cp -r "$SRC" "$FF_DIR/widevine" && echo "✅ Widevine 已部署"
fi

DUMP_FILE="$DUMP_DIR/verify-$(date +%Y%m%d-%H%M%S).h264"
rm -f "$DUMP_FILE"
LOG="$DUMP_DIR/firefox.log"
> "$LOG"

echo ""
echo "=== 启动参数 ==="
echo "  Dump:    $DUMP_FILE"
echo "  Log:     $LOG"
echo ""

export MOZ_STREAM_DUMP_PATH="$DUMP_FILE"
export MOZ_DISABLE_RDD_SANDBOX=1
export MOZ_ENABLE_WAYLAND=0
export DISPLAY=:1
export XAUTHORITY=/run/user/1000/gdm/Xauthority

setsid nohup "$FF" \
    -profile "$PROFILE" \
    -no-remote --new-instance \
    -remote-debugging-port 9222 \
    -remote-allow-origins '*' \
    "file:///tmp/test-local-mp4.html" \
    < /dev/null > "$LOG" 2>&1 &
FF_PID=$!
disown

echo "Firefox PID: $FF_PID"
sleep 5

if ! kill -0 $FF_PID 2>/dev/null; then
    echo "❌ Firefox 退出"
    cat "$LOG"
    exit 1
fi

# 探测循环：每 5s 一次
for i in 1 2 3 4 5 6; do
    echo ""
    echo "=== 探测 #$i (等待 5s) ==="
    sleep 5
    
    # 查 dump
    if [ -f "$DUMP_FILE" ]; then
        SIZE=$(stat -c%s "$DUMP_FILE")
        echo "  ✅ Dump 文件已生成 ($SIZE bytes)"
    else
        echo "  ❌ 暂无 dump"
    fi
    
    # 查 video 状态
    if [ -f /tmp/bidi-query.py ]; then
        python3 /tmp/bidi-query.py 2>&1 | head -25 || true
    fi
done

echo ""
echo "=== 最终状态 ==="
echo "Dump 文件: $(ls -la $DUMP_FILE 2>&1)"
echo ""
echo "--- log 末尾 40 行 ---"
tail -40 "$LOG"
echo ""
echo "--- StreamDumper 调用 ---"
grep "StreamDumper" "$LOG" | head -10
echo "(共 $(grep -c 'StreamDumper' $LOG) 条)"

echo ""
echo "PID $FF_PID 仍在跑"
