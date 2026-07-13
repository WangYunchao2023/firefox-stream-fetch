#!/bin/bash
# 抓取 yfsp.tv 完整视频（修复版：持久化 profile，保留 CF cookie）
set -e

PROJECT="/home/wangyc/Documents/软件类工作/firefox-stream-fetch"
PROFILE="/tmp/firefox-yfsp-persistent-profile"   # ← 固定名称，不删！
DUMP_DIR="/tmp/moz_stream_dumps"
mkdir -p "$DUMP_DIR"

# === 只在第一次创建 profile（保留 CF cookie）===
if [ ! -d "$PROFILE" ]; then
    mkdir -p "$PROFILE"
    cat > "$PROFILE/user.js" << 'PJ'
// === Autoplay / 媒体 ===
user_pref("media.autoplay.default", 0);
user_pref("media.autoplay.blocking_policy", 0);
user_pref("media.autoplay.allow-extension-background-events", true);
user_pref("media.suspend-bkgnd-video.enabled", false);
user_pref("browser.tabs.unloadOnLowMemory", false);

// === 关键: 强制 WebGL 用硬件加速（CF Turnstile 需要）===
// 解决 RenderCompositorSWGL failed 和 WebGL context lost
user_pref("webgl.force-enabled", true);
user_pref("webgl.disabled", false);
user_pref("webgl.disable-fail-if-major-performance-caveat", true);
user_pref("webgl.disable-extensions", false);
user_pref("webgl.enable-software-rendering", false);  // 禁掉软件回退
user_pref("webgl.force-layers-readback", false);
user_pref("webgl.software-renderer.enable", false);

// === 硬件加速（GPU 合成）===
user_pref("layers.acceleration.force-enabled", true);
user_pref("gfx.webrender.all", true);
user_pref("gfx.webrender.layers-free", true);
user_pref("gfx.compositor.glcontext", true);
user_pref("media.hardware-video-decoding.enabled", true);
user_pref("media.ffmpeg.vaapi.enabled", true);

// === 反指纹：仿 Chrome 的 User-Agent (提高 CF 通过率) ===
user_pref("general.useragent.override", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");

// === WebRTC 内网保护 ===
user_pref("media.peerconnection.ice.default_address_only", true);
user_pref("media.peerconnection.ice.no_host", true);

// === Navigator 信息补全（让指纹更接近正常 Chrome）===
user_pref("dom.webdriver.enabled", false);
user_pref("privacy.resistFingerprinting", false);
PJ
    echo "📁 新 profile 创建于 $PROFILE"
    echo "   ⚠️  首次使用需要手动过 Cloudflare 人机验证"
    echo "      之后重启脚本即可复用 cookie，无需再次验证"
    echo ""
fi

FF=$(find "$PROJECT/obj-stream" -name "firefox" -type f -executable 2>/dev/null | head -1)
FF_DIR=$(dirname "$FF")
echo "✅ Firefox: $FF"

if [ ! -d "$FF_DIR/widevine" ]; then
    SRC="$PROJECT/firefox-dist/widevine"
    [ -d "$SRC" ] && cp -r "$SRC" "$FF_DIR/widevine" && echo "✅ Widevine"
fi

DUMP_FILE="$DUMP_DIR/yfsp-$(date +%Y%m%d-%H%M%S).h264"
LOG="$DUMP_DIR/yfsp.log"
> "$LOG"

# === 始终走代理 ===
export MOZ_STREAM_DUMP_PATH="$DUMP_FILE"
export DISPLAY=:1
export XAUTHORITY=/run/user/1000/gdm/Xauthority
export http_proxy=http://127.0.0.1:19090
export https_proxy=http://127.0.0.1:19090

setsid nohup "$FF" \
    -profile "$PROFILE" \
    -no-remote --new-instance \
    "https://www.yfsp.tv/play/XSP8nCQJxQ9" \
    < /dev/null > "$LOG" 2>&1 &
FF_PID=$!
disown

echo "Firefox PID: $FF_PID"
echo "Dump: $DUMP_FILE"
echo "Log:  $LOG"
echo ""

# === 检查 CF 状态 ===
check_cloudflare() {
    if grep -q "challenges.cloudflare.com" "$LOG" 2>/dev/null; then
        return 0  # CF 在活动
    fi
    return 1
}

# === 监控循环 ===
LAST_SIZE=0
SAME_COUNT=0
i=0
CF_WARNED=0

while true; do
    sleep 10
    i=$((i+1))

    if ! kill -0 $FF_PID 2>/dev/null; then
        echo "[$i] Firefox 已退出"
        break
    fi

    # 检查是否被 CF 拦截
    if check_cloudflare && [ $CF_WARNED -eq 0 ]; then
        echo "[$i] ⚠️ Cloudflare 人机验证拦截中——请在 Firefox 窗口手动过验证"
        echo "     过完后脚本会自动开始抓取"
        CF_WARNED=1
    fi

    if [ -f "$DUMP_FILE" ]; then
        SIZE=$(stat -c%s "$DUMP_FILE")
        echo "[$i] ✅ Dump: $(numfmt --to=iec $SIZE)  (+$((SIZE-LAST_SIZE)))"
        if [ "$SIZE" = "$LAST_SIZE" ]; then
            SAME_COUNT=$((SAME_COUNT+1))
            if [ "$SAME_COUNT" -ge 6 ]; then
                echo "[$i] 📦 文件大小 60s 无变化，视频可能已播完✅"
                break
            fi
        else
            SAME_COUNT=0
        fi
        LAST_SIZE=$SIZE
    else
        echo "[$i] ⏳ 暂无 dump（等待视频加载或 CF 验证通过）"
    fi
done

# === 善后 ===
echo ""
echo "=== 最终结果 ==="
if [ -f "$DUMP_FILE" ]; then
    echo "Dump: $(ls -lh $DUMP_FILE)"
    FPS=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$DUMP_FILE" 2>/dev/null || echo 'N/A')
    DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$DUMP_FILE" 2>/dev/null || echo 'N/A')
    echo "Frames: $FPS"
    echo "Duration: ${DUR}s"
    echo ""
    echo "💡 可用 ffplay -f h264 '$DUMP_FILE' 播放"
    echo "   或 ffmpeg -c copy -o output.mp4 -i '$DUMP_FILE' 封装"
else
    echo "❌ 无 dump 文件"
    echo "   日志在 $LOG，检查 StreamDumper 是否触发的行："
    grep -i "StreamDumper\|dump" "$LOG" | head -5
fi
echo ""
echo "--- StreamDumper log ---"
grep StreamDumper "$LOG" | head -5
echo "(共 $(grep -c StreamDumper $LOG) 条)"
echo ""
echo "📝 下次运行时 profile 仍在 $PROFILE"
echo "   CF cookie 有效，无需重复人机验证"
