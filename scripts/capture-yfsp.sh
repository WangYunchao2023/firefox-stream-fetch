#!/bin/bash
# 抓取 yfsp.tv 完整视频（修复版：持久化 profile，保留 CF cookie）
set -e

PROJECT="/home/wangyc/Documents/软件类工作/firefox-stream-fetch"
PROFILE="/tmp/firefox-yfsp-persistent-profile"   # ← 固定名称，不删！
DUMP_DIR="/tmp/moz_stream_dumps"
mkdir -p "$DUMP_DIR"

# === 【每次跑都强制同步】代理 prefs 进 prefs.js ===
# user.js 里写了 network.proxy.*，但只在 profile 不存在时执行；
# 已有 profile 时，旧 prefs.js 里还残留上次错的 http://19090 proxy。
# 这里补丁 prefs.js 让 SOCKS5 必定生效，并纠正 anti-fingerprint 配置。
if [ -d "$PROFILE" ]; then
    PJS="$PROFILE/prefs.js"
    if [ -f "$PJS" ]; then
        # 先干掉旧的反指纹 / WebGL 错误配置（保留 network.proxy.* 干掉旧 key）
        sed -i \
            -e '/user_pref("general\.useragent\.override"/d' \
            -e '/user_pref("webgl\.software-renderer\.enable"/d' \
            -e '/user_pref("webgl\.out-of-process"/d' \
            -e '/user_pref("network\.proxy\.http"/d' \
            -e '/user_pref("network\.proxy\.ssl"/d' \
            -e '/user_pref("network\.proxy\.type"/d' \
            -e '/user_pref("network\.proxy\.socks"/d' \
            -e '/user_pref("network\.proxy\.socks_port"/d' \
            -e '/user_pref("network\.proxy\.socks_version"/d' \
            -e '/user_pref("network\.proxy\.socks_remote_dns"/d' \
            -e '/user_pref("network\.proxy\.no_proxies_on"/d' \
            "$PJS" 2>/dev/null || true
        cat >> "$PJS" <<'EP'
// === firefox-stream-fetch: 强制走 aurora SOCKS5 + 反指纹修复 (7/14 二次修) ===
user_pref("network.proxy.type", 1);
user_pref("network.proxy.socks", "127.0.0.1");
user_pref("network.proxy.socks_port", 29290);
user_pref("network.proxy.socks_version", 5);
user_pref("network.proxy.socks_remote_dns", true);
user_pref("network.proxy.no_proxies_on", "localhost, 127.0.0.1, ::1");
// 用 Firefox 真实 UA（不要 Chrome UA 跳 Firefox，会被 CF 看作 bot）
user_pref("general.useragent.updates.enabled", true);
user_pref("general.useragent.complexOverride", true);
// ETP：开 standard，CF 检查这个
user_pref("browser.contentblocking.category", "standard");
user_pref("privacy.trackingprotection.enabled", true);
user_pref("intl.accept_languages", "en-US,en;q=0.9");
user_pref("intl.locale.requested", "en-US");
// WebGL：硬件加速，绝对不要 software renderer
user_pref("webgl.software-renderer.enable", false);
EP
    fi
fi

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

// === 反指纹：不要改 UA ！让 Firefox 用真实 UA ===
//   改 Chrome UA 跑 Firefox 反而被 CF 识别为 bot
user_pref("general.useragent.updates.enabled", true);
user_pref("general.useragent.complexOverride", true);

// === WebRTC 内网保护 ===
user_pref("media.peerconnection.ice.default_address_only", true);
user_pref("media.peerconnection.ice.no_host", true);

// === Navigator 信息补全（让指纹看起来是个正常用户）===
user_pref("dom.webdriver.enabled", false);
user_pref("privacy.resistFingerprinting", false);

// === ETP (Enhanced Tracking Protection) — CF 看这个 ===
user_pref("browser.contentblocking.category", "standard");
user_pref("network.cookie.cookieBehavior", 4);   // 4=reject all 3rd party cookies（默认）
user_pref("privacy.trackingprotection.enabled", true);

// === 语言 / 时区 — 跟 SOCKS5 出口 IP 区域一致（这里默认 en-US）===
user_pref("intl.accept_languages", "en-US,en;q=0.9");
user_pref("intl.locale.requested", "en-US");

// === 代理：aurora-slim 的 SOCKS5 (29290) 才能走 HTTPS ===
//   19090 是 HTTP forward proxy，不支持 CONNECT，HTTPS 走它会 405
//   18090 也是 HTTP-only（会返回 301 redirect 假冒隧道）
//   SOCKS5 + remote DNS 才能让 CF / Turnstile 拿到干净的出口 IP
user_pref("network.proxy.type", 1);                        // 0=direct, 1=manual, 4=SOCKS
user_pref("network.proxy.socks", "127.0.0.1");
user_pref("network.proxy.socks_port", 29290);
user_pref("network.proxy.socks_version", 5);
user_pref("network.proxy.socks_remote_dns", true);
user_pref("network.proxy.no_proxies_on", "localhost, 127.0.0.1, ::1");

// === WebGL：走硬件加速，绝对不要 software renderer（CF 看作 bot） ===
//   之前 webgl.software-renderer.enable=true 是错误：让 renderer 变 SwiftShader
//   CF Turnstile 拿 WebGL UNMASKED_RENDERER_WEBGL 当指纹、SwiftShader → 高风险 → 拒绝 cookie
user_pref("webgl.force-enabled", true);
user_pref("webgl.disabled", false);
user_pref("webgl.force-layers-readback", false);
// 硬件加速全开，让 WebGL 走 GPU process
user_pref("layers.acceleration.force-enabled", true);
user_pref("gfx.webrender.all", true);
user_pref("gfx.webrender.layers-free", true);
user_pref("gfx.compositor.glcontext", true);
user_pref("media.hardware-video-decoding.enabled", true);
user_pref("media.ffmpeg.vaapi.enabled", true);
// 容忍「context lost」（CF challenge 重试是正常现象）
user_pref("webgl.disable-fail-if-major-performance-caveat", true);

// === 不让 challenge 后页面跳转被中途截断 ===
user_pref("dom.disable_open_during_load", false);

// === 抑制 deprecated 警告刷屏 ===
user_pref("dom.webgl.disabled-extensions.warn-on-use", false);
PJ
    echo "📁 新 profile 创建于 $PROFILE"
    echo "   ⚠️  首次使用需要手动过 Cloudflare 人机验证"
    echo "      之后重启脚本即可复用 cookie，无需再次验证"
    echo ""
fi

FF=$(find -L "$PROJECT/obj-stream" -path "*dist/bin/firefox" -type f -executable 2>/dev/null | head -1)
FF_DIR=$(dirname "$FF")
echo "✅ Firefox: $FF"

if [ ! -d "$FF_DIR/widevine" ]; then
    SRC="$PROJECT/firefox-dist/widevine"
    [ -d "$SRC" ] && cp -r "$SRC" "$FF_DIR/widevine" && echo "✅ Widevine"
fi

DUMP_FILE="$DUMP_DIR/yfsp-$(date +%Y%m%d-%H%M%S).h264"
LOG="$DUMP_DIR/yfsp.log"
> "$LOG"

# === 代理走 user.js 里的 network.proxy.socks（见上方）===
# 旧版误用 http://127.0.0.1:19090，那个端口是 HTTP forward proxy，
# Firefox HTTPS 会发 CONNECT，被代理 405 Method Not Allowed。
# 真正能走 HTTPS 的是 aurora-slim 的 SOCKS5 端口 29290（curl 实测 baidu 200 OK）。
export MOZ_STREAM_DUMP_PATH="$DUMP_FILE"
export DISPLAY=:1
export XAUTHORITY=/run/user/1000/gdm/Xauthority
# 保留 env 变量不影响 Firefox（它不读 SOCKS5_SERVER），
# 万一脚本里某条 curl/ffprobe 调用想用它兜底也行。
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY 2>/dev/null
export SOCKS5_SERVER=socks5://127.0.0.1:29290
export SOCKS_PROXY=socks5://127.0.0.1:29290

setsid nohup "$FF" \
    -profile "$PROFILE" \
    -no-remote --new-instance \
    "https://www.yfsp.tv/play/zImbBGABDR2" \
    < /dev/null > "$LOG" 2>&1 &
FF_PID=$!
disown

echo "Firefox PID: $FF_PID"
echo "Dump: $DUMP_FILE"
echo "Log:  $LOG"

# === 拉窗口到前台 ===
# 上次发现窗口被置为 1x1 + (0,0) 完全看不见，
# 因为 setsid 脱壳后 WM 没拿到 geometry。
# 轮询 15s 等窗口起来，再 move+resize+activate。
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1.5
    # --name 默认是子串匹配，不是 regex。
    # 联合 title / classname 一起匹配（「firefox-default」是 className）。
    WID=$(XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
        xdotool search "Just a moment" 2>/dev/null \
        | grep -v '^$' | head -1)
    [ -z "$WID" ] && WID=$(XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
        xdotool search --classname "firefox-default" 2>/dev/null \
        | grep -v '^$' | head -1)
    if [ -n "$WID" ]; then
        echo "🪟 找到 Firefox 窗口 WID=$WID（尝试 $i）"
        XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
            xdotool windowsize "$WID" 1280 800 2>/dev/null
        XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
            xdotool windowmove "$WID" 200 100 2>/dev/null
        XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
            xdotool windowactivate "$WID" 2>/dev/null
        XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
            xdotool windowraise "$WID" 2>/dev/null
        break
    fi
done
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
