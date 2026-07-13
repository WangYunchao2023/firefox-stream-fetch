#!/bin/bash
# 测试 YouTube 视频抓取
# 重要：不自动 kill Firefox！让你手动登录 / 看视频 / 决定何时结束
set -e

PROJECT="/home/wangyc/Documents/软件类工作/firefox-stream-fetch"
PROFILE="/tmp/firefox-youtube-persistent-profile"
DUMP_DIR="/tmp/moz_stream_dumps"
mkdir -p "$DUMP_DIR"

# === Profile 管理（首次创建，之后保留——保留登录 cookie）===
if [ ! -d "$PROFILE" ]; then
    mkdir -p "$PROFILE"
    cat > "$PROFILE/user.js" << 'PJ'
user_pref("media.autoplay.default", 0);
user_pref("media.autoplay.blocking_policy", 0);
user_pref("media.autoplay.allow-extension-background-events", true);
user_pref("media.suspend-bkgnd-video.enabled", false);
user_pref("browser.tabs.unloadOnLowMemory", false);

user_pref("webgl.force-enabled", true);
user_pref("webgl.disabled", false);
user_pref("webgl.enable-software-rendering", true);

user_pref("layers.acceleration.force-enabled", true);
user_pref("gfx.webrender.all", true);
user_pref("media.hardware-video-decoding.enabled", true);

user_pref("security.sandbox.content.level", 0);
user_pref("security.sandbox.gmp.level", 0);
user_pref("security.sandbox.rdd.level", 0);
user_pref("security.sandbox.socket.level", 0);
user_pref("security.sandbox.utility.level", 0);

user_pref("media.eme.enabled", true);
user_pref("media.eme.chromium-build-parameters", false);
PJ
    echo "📁 新 profile 创建于 $PROFILE"
else
    echo "📁 复用 profile $PROFILE（保留登录 cookie）"
fi

FF=$(find "$PROJECT/obj-stream" -name "firefox" -type f -executable 2>/dev/null | head -1)
FF_DIR=$(dirname "$FF")
echo "✅ Firefox: $FF"

if [ ! -d "$FF_DIR/widevine" ]; then
    SRC="$PROJECT/firefox-dist/widevine"
    [ -d "$SRC" ] && cp -r "$SRC" "$FF_DIR/widevine" && echo "✅ Widevine"
fi

DUMP_FILE="$DUMP_DIR/youtube-$(date +%Y%m%d-%H%M%S).h264"
LOG="$DUMP_DIR/youtube.log"
> "$LOG"

export MOZ_STREAM_DUMP_PATH="$DUMP_FILE"
export MOZ_DISABLE_RDD_SANDBOX=1
export DISPLAY=:1
export XAUTHORITY=/run/user/1000/gdm/Xauthority
export http_proxy=http://127.0.0.1:19090
export https_proxy=http://127.0.0.1:19090

YOUTUBE_URL="${1:-https://www.youtube.com/watch?v=_n4SRDYkhqs}"

# 启动 Firefox（前台不阻塞）
setsid nohup "$FF" \
    -profile "$PROFILE" \
    -no-remote --new-instance \
    "$YOUTUBE_URL" \
    < /dev/null > "$LOG" 2>&1 &
FF_PID=$!
disown

echo "Firefox PID: $FF_PID"
echo "Dump: $DUMP_FILE"
echo "Log:  $LOG"
echo "URL:  $YOUTUBE_URL"
echo ""
echo "✋ Firefox 在前台运行——请你手动登录 + 播放视频"
echo "   脚本只监控，不会自动 kill Firefox"
echo "   想停止时按 Ctrl+C"
echo ""

# === 仅监控，绝不自动退出 ===
LAST_SIZE=0
NO_DUMP_WARN=0

while true; do
    sleep 15

    if ! kill -0 $FF_PID 2>/dev/null; then
        echo ""
        echo "[!] Firefox 已退出"
        break
    fi

    if [ -f "$DUMP_FILE" ]; then
        SIZE=$(stat -c%s "$DUMP_FILE")
        GROW=$((SIZE-LAST_SIZE))
        if [ "$SIZE" -gt 0 ]; then
            echo "[$(date +%H:%M:%S)] ✅ Dump: $(numfmt --to=iec $SIZE) (+$GROW)"
        else
            echo "[$(date +%H:%M:%S)] ⚠️  dump 存在但 size=0"
        fi
        LAST_SIZE=$SIZE
    else
        NO_DUMP_WARN=$((NO_DUMP_WARN+1))
        if [ "$NO_DUMP_WARN" -le 4 ]; then
            echo "[$(date +%H:%M:%S)] ⏳ 暂无 dump（请在 Firefox 窗口登录并播放视频）"
        elif [ "$NO_DUMP_WARN" -eq 5 ]; then
            echo "[$(date +%H:%M:%S)] 💡 提示：还在等登录/播放？用 ps 看 Firefox 状态"
        else
            # 5 之后只在 dump 出现时显示
            :
        fi
    fi
done

echo ""
echo "=== 最终结果 ==="
if [ -f "$DUMP_FILE" ] && [ "$(stat -c%s $DUMP_FILE)" -gt 0 ]; then
    echo "✅ Dump 文件存在: $(ls -lh $DUMP_FILE)"
    FPS=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$DUMP_FILE" 2>/dev/null || echo 'N/A')
    DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$DUMP_FILE" 2>/dev/null || echo 'N/A')
    echo "Frames: $FPS"
    echo "Duration: ${DUR}s"
    echo ""
    echo "💡 ffplay -f h264 '$DUMP_FILE' 播放"
else
    echo "❌ 无 dump 或 dump 为空"
    echo ""
    echo "检查项："
    echo "  - Firefox 窗口里视频是否真正在播放"
    echo "  - 浏览器控制台是否有 DRM 错误"
    echo ""
    echo "StreamDumper 日志："
    grep StreamDumper "$LOG" | tail -5 || echo "（无）"
    echo ""
    echo "Widevine/CDM 相关："
    grep -iE "widevine|cdm|eme" "$LOG" | head -5 || echo "（无）"
fi
