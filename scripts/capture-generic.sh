#!/bin/bash
# 通用视频抓取脚本 — 任何 CF Turnstile 网站都能用
#
# ═══════════════════════════════════════════════════════════════════════
# 用法
# ═══════════════════════════════════════════════════════════════════════
#   ./capture-generic.sh URL [PROFILE_NAME]
#
#   URL          - 必填，任意 HTTP(S) URL（如视频页）
#   PROFILE_NAME - 可选，profile 名（默认：基于 URL 域名+hash，自动生成）
#
# 例子:
#   ./capture-generic.sh https://www.yfsp.tv/play/zImbBGABDR2
#   ./capture-generic.sh https://www.youtube.com/watch?v=xxx youtube
#   ./capture-generic.sh https://example.com/video example
#
# ═══════════════════════════════════════════════════════════════════════
# 流程
# ═══════════════════════════════════════════════════════════════════════
#   1. 检查对应 profile 是否有有效 cf_clearance cookie
#      ├─ 有 → 跳到 Phase 2（dump）
#      └─ 无 → Phase 1（sandbox 正常 + Firefox 真实 UA）
#              启动 Firefox → 人工过 CF（如果需要）→ 视频播放
#              等待 Firefox 退出（崩溃/手动关闭）
#   2. Phase 2: 同 profile + sandbox 关闭 + MOZ_STREAM_DUMP_PATH
#              启动 Firefox → cookie 复用 → CF 跳过 → 视频播放
#              → StreamDumper 写 dump
#   3. 监控 dump 文件增长，2 分钟无增长视为播放完成
#   4. 自动 ffmpeg 转封装 .mp4
# ═══════════════════════════════════════════════════════════════════════
set -e

PROJECT="/home/wangyc/Documents/软件类工作/firefox-stream-fetch"
FF=$(find -L "$PROJECT/obj-stream" -path "*dist/bin/firefox" -type f -executable 2>/dev/null | head -1)
[ -z "$FF" ] && { echo "❌ 找不到 firefox"; exit 1; }

if [ -z "$1" ]; then
    echo "用法: $0 URL [PROFILE_NAME]"
    echo "  ./capture-generic.sh https://www.yfsp.tv/play/zImbBGABDR2"
    echo "  ./capture-generic.sh https://example.com/video example"
    exit 1
fi
URL="$1"

# ─────────────────────────────────────────────────────────────
# 解析 URL 域名 → 自动生成 profile 名（如果用户没指定）
# ─────────────────────────────────────────────────────────────
if [ -n "$2" ]; then
    PROFILE_NAME="$2"
else
    # 从 URL 提取域名，去 www.，再规范化作为 profile 名
    DOMAIN=$(echo "$URL" | sed -E 's|^https?://||; s|/.*$||; s|^www\.||')
    # 只保留字母数字下划线
    PROFILE_NAME=$(echo "$DOMAIN" | tr -cd 'a-zA-Z0-9_')
    # 太短就用 hash
    if [ ${#PROFILE_NAME} -lt 3 ]; then
        PROFILE_NAME="profile-$(echo -n "$URL" | md5sum | cut -c1-8)"
    fi
fi
PROFILE="/tmp/firefox-stream-$PROFILE_NAME"

# 输出目录 + 文件
DUMP_DIR="/tmp/moz_stream_dumps"
mkdir -p "$DUMP_DIR"
TS=$(date +%Y%m%d-%H%M%S)
DUMP_FILE="$DUMP_DIR/${PROFILE_NAME}-${TS}.h264"
LOG="$DUMP_DIR/${PROFILE_NAME}-${TS}.log"
> "$LOG"

export DISPLAY=:1
export XAUTHORITY=/run/user/1000/gdm/Xauthority

# dump 多久没增长算"播放完成"（秒）
DUMP_STALL_TIMEOUT=120
# Phase 1 静默等待超时（30 分钟）
PHASE1_TIMEOUT=1800

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  firefox-stream-fetch 通用抓取脚本                          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "  URL:           $URL"
echo "  Profile:       $PROFILE"
echo "  Profile name:  $PROFILE_NAME"
echo "  Dump file:     $DUMP_FILE"
echo ""

# ─────────────────────────────────────────────────────────────
# 公共函数
# ─────────────────────────────────────────────────────────────
clear_locks() {
    rm -f "$PROFILE/.parentlock" "$PROFILE/parent.lock" "$PROFILE/lock"
}

kill_profile_firefox() {
    # 杀掉使用该 profile 的所有 firefox
    for PID in $(ps -ef | grep -v grep | grep "$PROFILE" | awk '{print $2}'); do
        EXE=$(readlink -f /proc/$PID/exe 2>/dev/null)
        CMD=$(cat /proc/$PID/cmdline 2>/dev/null | tr '\0' ' ')
        # 只杀主进程（避免杀 crashhelper / contentproc）
        if echo "$EXE" | grep -q "firefox-stream-fetch" && echo "$CMD" | grep -q "$PROFILE "; then
            kill -9 "$PID" 2>/dev/null
        fi
    done
    sleep 2
    clear_locks
}

pull_window_front() {
    local WID
    sleep 3
    for i in 1 2 3 4 5 6 7 8; do
        WID=$(XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
            xdotool search --name "Just a moment\|Nightly\|${PROFILE_NAME}" 2>/dev/null | head -1)
        [ -z "$WID" ] && WID=$(XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
            xdotool search --classname "firefox-default" 2>/dev/null | head -1)
        if [ -n "$WID" ]; then
            XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
                xdotool windowsize "$WID" 1280 800 &>/dev/null
            XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
                xdotool windowmove "$WID" 200 100 &>/dev/null
            XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
                xdotool windowactivate "$WID" windowraise "$WID" &>/dev/null
            return 0
        fi
        sleep 1
    done
}

enable_sandbox_prefs() {
    PJS="$PROFILE/prefs.js"
    if [ -f "$PJS" ]; then
        sed -i '/user_pref("security\.sandbox/d' "$PJS" 2>/dev/null || true
    fi
    cat >> "$PJS" <<'EP'
// === Phase 1: sandbox 默认 ===
user_pref("security.sandbox.content.level", 7);
user_pref("security.sandbox.gmp.level", 4);
user_pref("security.sandbox.rdd.level", 4);
user_pref("security.sandbox.socket.level", 1);
user_pref("security.sandbox.utility.level", 1);
user_pref("security.sandbox.gpu.level", 1);
EP
}

disable_sandbox_prefs() {
    PJS="$PROFILE/prefs.js"
    if [ -f "$PJS" ]; then
        sed -i '/user_pref("security\.sandbox/d' "$PJS" 2>/dev/null || true
    fi
    cat >> "$PJS" <<'EP'
// === Phase 2: 关 sandbox 让 StreamDumper 写文件 ===
user_pref("security.sandbox.content.level", 0);
user_pref("security.sandbox.gmp.level", 0);
user_pref("security.sandbox.rdd.level", 0);
user_pref("security.sandbox.socket.level", 0);
user_pref("security.sandbox.utility.level", 0);
EP
}

has_valid_cf_cookie() {
    if [ ! -f "$PROFILE/cookies.sqlite" ]; then
        return 1
    fi
    local count
    count=$(sqlite3 "$PROFILE/cookies.sqlite" \
        "SELECT COUNT(*) FROM moz_cookies 
         WHERE name='cf_clearance' AND expiry > strftime('%s','now')" 2>/dev/null || echo 0)
    [ "$count" -gt 0 ]
}

# ─────────────────────────────────────────────────────────────
# Phase 1: 拿 CF cookie（sandbox 正常）
# ─────────────────────────────────────────────────────────────────
phase1() {
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  Phase 1 — 获取 cf_clearance（sandbox 正常）              ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    # 全新 profile
    rm -rf "$PROFILE"
    mkdir -p "$PROFILE"

    # 关键 user.js：sandbox 默认 + Firefox 真实 UA
    # 严禁：useragent.override、sandbox.*.level = 0
    cat > "$PROFILE/user.js" << PJEOF
user_pref("network.proxy.type", 5);
user_pref("media.autoplay.default", 0);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.sessionstore.max_resumed_crashes", 0);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.shell.skipDefaultBrowserCheckOnFirstRun", true);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.messaging-system.whatsNewPanel.enabled", false);
user_pref("dom.webdriver.enabled", false);
user_pref("privacy.resistFingerprinting", false);
PJEOF

    clear_locks
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY MOZ_STREAM_DUMP_PATH

    echo "🚀 启动 Firefox（Phase 1：sandbox 默认）..."
    setsid nohup "$FF" \
        -profile "$PROFILE" \
        -no-remote --new-instance \
        "$URL" \
        < /dev/null > "$LOG" 2>&1 &
    PHASE1_PID=$!
    disown

    pull_window_front

    echo ""
    echo "┌──────────────────────────────────────────────────────────┐"
    echo "│  👆  浏览器已打开 URL：$URL"
    echo "│"
    echo "│  如果需要 Cloudflare 验证，请在窗口中手动通过"
    echo "│  （如果不需要 CF，直接播放视频即可）"
    echo "│"
    echo "│  Firefox 通过 CF 验证后可能自动崩溃（patched build"
    echo "│  WebGL 限制），cookie 会自动落盘。"
    echo "│"
    echo "│  静默等待中（超时 $PHASE1_TIMEOUT 秒）..."
    echo "└──────────────────────────────────────────────────────────┘"
    echo ""

    # 静默等待 Firefox 退出
    local elapsed=0
    while kill -0 "$PHASE1_PID" 2>/dev/null; do
        sleep 10
        elapsed=$((elapsed + 10))
        if [ $elapsed -gt $PHASE1_TIMEOUT ]; then
            echo "⏰ 等待超时，强制结束"
            kill -9 "$PHASE1_PID" 2>/dev/null
            break
        fi
    done
    echo "  ✅ Firefox 已退出"
}

# ─────────────────────────────────────────────────────────────
# Phase 2: StreamDumper 抓取（sandbox 关闭）
# ─────────────────────────────────────────────────────────────────────────────
phase2() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  Phase 2 — StreamDumper 抓取（sandbox 关闭）              ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    disable_sandbox_prefs
    clear_locks

    export MOZ_STREAM_DUMP_PATH="$DUMP_FILE"
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY

    echo "📦 Dump: $DUMP_FILE"
    echo "🚀 重启 Firefox（Phase 2：sandbox 关闭）..."
    setsid nohup "$FF" \
        -profile "$PROFILE" \
        -no-remote --new-instance \
        "$URL" \
        < /dev/null >> "$LOG" 2>&1 &
    PHASE2_PID=$!
    disown

    pull_window_front

    # 监控 dump
    local last_size=0
    local stall_count=0
    local dump_started=0

    echo ""
    echo "  ⏳ 监控 dump（每 10 秒）..."
    echo "  停止条件：dump 文件 $DUMP_STALL_TIMEOUT 秒无增长"
    echo ""

    while kill -0 "$PHASE2_PID" 2>/dev/null; do
        sleep 10
        if [ -f "$DUMP_FILE" ]; then
            local size=$(stat -c%s "$DUMP_FILE")
            if [ "$size" -gt "$last_size" ]; then
                local delta=$((size - last_size))
                echo "  ✅ $(numfmt --to=iec $size)  (+$(numfmt --to=iec $delta))"
                last_size=$size
                stall_count=0
                dump_started=1
            else
                stall_count=$((stall_count+1))
                if [ $stall_count -ge $((DUMP_STALL_TIMEOUT/10)) ]; then
                    echo "  📦 ${DUMP_STALL_TIMEOUT}s 无增长，停止"
                    kill -15 "$PHASE2_PID" 2>/dev/null
                    break
                fi
            fi
        else
            echo "  ⏳ 暂无 dump（等待视频加载）"
        fi
    done

    if [ $dump_started -eq 0 ]; then
        echo "  ⚠️  Phase 2 期间无 dump（视频未开始播放？）"
    fi
}

# ─────────────────────────────────────────────────────────────
# 后处理：mp4 封装
# ─────────────────────────────────────────────────────────────────────────────
post_process() {
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  最终结果"
    echo "════════════════════════════════════════════════════════════"
    if [ ! -f "$DUMP_FILE" ] || [ ! -s "$DUMP_FILE" ]; then
        echo "❌ 无 dump 文件"
        echo "日志: $LOG"
        grep "StreamDumper" "$LOG" | head -5
        return 1
    fi

    echo ""
    echo "📦 H.264 dump: $(ls -lh $DUMP_FILE | awk '{print $5}')"
    local OUT="${DUMP_FILE%.h264}.mp4"
    echo "📦 转封装 mp4:"
    ffmpeg -y -framerate 15 -i "$DUMP_FILE" -c:v copy -movflags +faststart "$OUT" 2>&1 | tail -3
    echo ""
    echo "✅ mp4: $OUT"
    ls -lh "$OUT"
    echo ""
    ffprobe -v error -show_format -show_streams "$OUT" 2>&1 \
        | grep -E "codec_name|profile|width|height|duration=|nb_frames" | head -10
    echo ""
    echo "💡 播放: ffplay '$OUT'"
}

# ─────────────────────────────────────────────────────────────
# 主流程
# ─────────────────────────────────────────────────────────────
# 1. 杀掉任何使用该 profile 的旧 Firefox
kill_profile_firefox

# 2. 检查 cookie
if has_valid_cf_cookie; then
    echo "✅ profile 里有有效 cf_clearance cookie，跳过 Phase 1"
    echo ""
    phase2
    post_process
else
    phase1
    # 杀掉可能自动恢复的 Firefox
    kill_profile_firefox
    if has_valid_cf_cookie; then
        echo "✅ Phase 1 完成 — cf_clearance 已落盘"
        phase2
        post_process
    else
        echo ""
        echo "❌ 未检测到 cf_clearance cookie"
        echo "  可能原因："
        echo "  - 你没有完成 CF 验证"
        echo "  - 该网站不需要 CF，但你也没让视频播放"
        echo "  重新跑一次脚本即可再试。"
        exit 1
    fi
fi
