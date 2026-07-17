#!/bin/bash
# firefox-stream-fetch capture.sh — v3.0 统一入口
#
# 用法:
#   capture.sh [URL] [OPTIONS]
#
# URL — 可选。不填则 Phase 1 开 about:newtab，用户在 Firefox 地址栏手动输入
# OPTIONS:
#   --output DIR              保存目录（默认：~/Videos/firefox抓取/）
#   --auto-next               playlist 自动连集（占位：v3.1 实现 monitor 侧切集检测）
#   --skip-phase1             跳过 Phase 1（profile 已有 cf_clearance 时等价行为）
#   --keep-h264               保留 .h264/.aac 中间文件（默认封 mp4 后清理）
#   --profile PATH            指定 profile 路径（默认按 URL host 自动命名）
#   --help                    帮助
#
# 行为:
#   - Phase 1: 同 profile + 同 patched Firefox，sandbox 默认 + 真实 UA，过 CF / 加载页面
#   - Phase 2: 同 profile 同 URL，sandbox 关闭（让 StreamDumper 写盘），从头加载抓流
#   - 代理: 读 *proxy 环境变量；Phase 1 显式 unset 避免 CF 检测改 env
#   - 反指纹: 一组最小 prefs（capture-generic / capture-yfsp v2.2 已验证）
#   - 智能监控: lib-monitor.sh（BiDi + ended / stalled / paused / no-video）
#   - 输出:
#       - $OUTPUT_DIR/<host>-<timestamp>.mp4
#       - $OUTPUT_DIR/<host>-<timestamp>.log
#       - $OUTPUT_DIR/<host>-<timestamp>.sidecar.json（resume 用）
#
set -e

PROJECT="/home/wangyc/Documents/软件类工作/firefox-stream-fetch"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ═══════════════════════════════════════════════════════════════════════
# 默认参数
# ═══════════════════════════════════════════════════════════════════════
OUTPUT_DIR="$HOME/Videos/firefox抓取"
AUTO_NEXT=0
SKIP_PHASE1=0
KEEP_H264=0
URL=""
PROFILE_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)          OUTPUT_DIR="$2"; shift 2;;
        --auto-next)       AUTO_NEXT=1; shift;;
        --skip-phase1)     SKIP_PHASE1=1; shift;;
        --keep-h264)       KEEP_H264=1; shift;;
        --profile)         PROFILE_PATH="$2"; shift 2;;
        --help|-h)
            cat <<HELP
firefox-stream-fetch 统一抓取脚本 v3.0

用法:
    capture.sh [URL] [OPTIONS]

URL:
    不填写 → Phase 1 开空白页，在 Firefox 地址栏手动输入
    填写   → 直接作为初始 URL

OPTIONS:
    --output DIR              mp4 保存目录（默认：~/Videos/firefox抓取/）
    --auto-next               playlist 自动连集（每集独立 mp4：host-01.mp4, host-02.mp4...）
    --skip-phase1             跳过 Phase 1（profile 已有可用 cookie 时等价行为）
    --keep-h264               保留 .h264/.aac 中间文件（默认封 mp4 后删除）
    --profile PATH            自定义 profile 路径

例子:
    capture.sh
    capture.sh https://www.olevod.com/player/vod/1-82695-1.html
    capture.sh https://www.yfsp.tv/watch?v=ztgsSWh5mPZEhhazLjYUG6 --auto-next
    capture.sh https://www.youtube.com/watch?v=_n4SRDYkhqs --keep-h264

环境变量:
    http_proxy / https_proxy / all_proxy    系统代理（任意一个设了就生效）
                                                无则直联
HELP
            exit 0;;
        http://*|https://*|file://*) URL="$1"; shift;;
        *)              echo "未知参数: $1"; exit 1;;
    esac
done

# ═══════════════════════════════════════════════════════════════════════
# 推导常量
# ═══════════════════════════════════════════════════════════════════════
FF=$(find -L "$PROJECT/obj-stream" -path "*dist/bin/firefox" -type f -executable 2>/dev/null | head -1)
[ -z "$FF" ] && { echo "❌ 找不到 patched firefox（$PROJECT/obj-stream/*/dist/bin/firefox）"; exit 1; }
FF_DIR=$(dirname "$FF")

mkdir -p "$OUTPUT_DIR"
[ ! -d "$OUTPUT_DIR" ] && { echo "❌ 无法创建输出目录 $OUTPUT_DIR"; exit 1; }

if [ -n "$PROFILE_PATH" ]; then
    PROFILE="$PROFILE_PATH"
else
    if [ -n "$URL" ]; then
        HOST=$(echo "$URL" | sed -E 's|^https?://([^/]+).*|\1|; s|^www\.||')
        PROFILE_NAME=$(echo "$HOST" | tr -cd 'a-zA-Z0-9_.-' | cut -c1-40)
        [ ${#PROFILE_NAME} -lt 3 ] && PROFILE_NAME="manual-$(date +%Y%m%d-%H%M%S)"
    else
        PROFILE_NAME="manual-$(date +%Y%m%d-%H%M%S)"
    fi
    PROFILE="/tmp/firefox-stream-$PROFILE_NAME"
fi

TS=$(date +%Y%m%d-%H%M%S)
BASE_NAME="$(basename "$PROFILE" | sed 's|^firefox-stream-||')"
LOG="$OUTPUT_DIR/${BASE_NAME}-${TS}.log"

# 输出文件名（基名）
OUT_BASE() {
    if [ $AUTO_NEXT -eq 1 ] && [ -n "${EPISODE:-}" ] && [ "$EPISODE" -gt 1 ]; then
        echo "$OUTPUT_DIR/${BASE_NAME}-$(printf '%02d' $EPISODE)"
    else
        echo "$OUTPUT_DIR/${BASE_NAME}-${TS}"
    fi
}

export DISPLAY=${DISPLAY:-:1}
export XAUTHORITY=${XAUTHORITY:-/run/user/1000/gdm/Xauthority}
export MOZ_ENABLE_WAYLAND=0
export GDK_BACKEND=x11

# ═══════════════════════════════════════════════════════════════════════
# 公共：代理策略
# ------------------------------------------------------------------------
#   Phase 1: 显式 unset 所有 proxy（不接管用户环境，避免 CF 检测改 env）
#   Phase 2: 把 *proxy 透传给 firefox（firefox 自动尊重 env）
# ═══════════════════════════════════════════════════════════════════════
_clear_proxy_env() {
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY socks_proxy SOCKS_PROXY
}

_apply_proxy_env() {
    : # noop: 环境变量自然继承
}

has_proxy_env() {
    [ -n "${http_proxy:-}${https_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}${all_proxy:-}${ALL_PROXY:-}" ]
}

# ═══════════════════════════════════════════════════════════════════════
# 公共：wid / 标题 / 拉前台
# ═══════════════════════════════════════════════════════════════════════
clear_locks() {
    rm -f "$PROFILE/.parentlock" "$PROFILE/parent.lock" "$PROFILE/lock"
}

get_firefox_wid() {
    XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" \
        xdotool search --name "Nightly" 2>/dev/null | head -1
}

get_firefox_title() {
    [ -n "$1" ] && XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" \
        xdotool getwindowname "$1" 2>/dev/null
}

pull_window_front() {
    sleep 3
    for i in 1 2 3 4 5 6 7 8 9 10; do
        local WID
        WID=$(get_firefox_wid)
        if [ -n "$WID" ]; then
            XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" \
                xdotool windowsize "$WID" 1280 800 &>/dev/null
            XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" \
                xdotool windowmove "$WID" 200 100 &>/dev/null
            XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" \
                xdotool windowactivate "$WID" windowraise "$WID" &>/dev/null
            return 0
        fi
        sleep 1
    done
}

# ═══════════════════════════════════════════════════════════════════════
# 公共：检查 profile 是否有可用 cf_clearance
# ═══════════════════════════════════════════════════════════════════════
has_valid_cf_cookie() {
    [ -f "$PROFILE/cookies.sqlite" ] || return 1
    local count
    count=$(sqlite3 "$PROFILE/cookies.sqlite" \
        "SELECT COUNT(*) FROM moz_cookies WHERE name='cf_clearance' AND expiry > strftime('%s','now')" \
        2>/dev/null || echo 0)
    [ "$count" -gt 0 ]
}

# ═══════════════════════════════════════════════════════════════════════
# Phase 1 — 用户交互阶段（让人过 CF / 输入 URL）
# ═══════════════════════════════════════════════════════════════════════
phase1() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  Phase 1 — 过验证 / 加载页面                                ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    # profile 复用（如有可用 cookie，直接进 Phase 2）
    if has_valid_cf_cookie; then
        echo "✅ 检测到现有有效 cf_clearance cookie → 跳过 Phase 1"
        return 0
    fi

    # 准备新 profile（或复用现有，但开始清 prefs）
    mkdir -p "$PROFILE"
    cat > "$PROFILE/user.js" << 'PJEOF'
// === v3.0 Phase 1 反指纹 prefs（实测通过 CF Turnstile） ===
user_pref("network.proxy.type", 5);
user_pref("media.autoplay.default", 0);
user_pref("browser.startup.page", 3);
user_pref("browser.sessionstore.resume_from_crash", true);
user_pref("browser.sessionstore.max_resumed_crashes", 1);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.shell.skipDefaultBrowserCheckOnFirstRun", true);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.messaging-system.whatsNewPanel.enabled", false);
user_pref("dom.webdriver.enabled", false);
user_pref("privacy.resistFingerprinting", false);
PJEOF

    clear_locks
    export MOZ_STREAM_DUMP_PATH="/dev/null"
    _clear_proxy_env

    local start_url="${URL:-about:newtab}"
    echo "🚀 启动 Firefox（Phase 1: sandbox 默认 + 不开 BiDi）..."
    echo "   起始 URL: $start_url"

    setsid nohup "$FF" \
        -profile "$PROFILE" \
        -no-remote --new-instance \
        "$start_url" \
        < /dev/null > "$LOG" 2>&1 &
    local PID=$!
    disown
    pull_window_front
    local WID=$(get_firefox_wid)

    echo ""
    echo "┌──────────────────────────────────────────────────────────┐"
    echo "│  👆  Firefox 已打开，请按需操作：                        │"
    if [ -z "$URL" ]; then
        echo "│    在地址栏输入视频页面 URL"
    fi
    echo "│    若弹出 CF 人机验证，请手动通过                        │"
    echo "│                                                          │"
    echo "│  脚本会通过窗口标题自动检测页面加载完成                    │"
    echo "│  检测到后会自动进入 Phase 2                               │"
    echo "└──────────────────────────────────────────────────────────┘"
    echo ""

    echo "  🔍 每 3s 检查窗口标题..."
    local saw_cf=0
    local elapsed=0
    local PHASE1_TIMEOUT=1800

    while kill -0 "$PID" 2>/dev/null; do
        sleep 3
        elapsed=$((elapsed + 3))

        local title
        title=$(get_firefox_title "$WID")
        if [ -n "$title" ]; then
            if echo "$title" | grep -qi "Just a moment"; then
                [ $saw_cf -eq 0 ] && echo "  [$elapsed s] ⏳ CF 挑战中..." && saw_cf=1
            elif [[ "$title" != "Nightly" &&
                    "$title" != "Firefox" &&
                    "$title" != "New Tab" &&
                    "$title" != "about:home" &&
                    "$title" != "about:newtab" ]]; then
                echo "  ✅ [$elapsed s] 检测到页面加载完成（标题: '$title'）"
                # 给页面再 2s 让 MediaSource 进入 first segment
                sleep 2
                echo "  🔪 关闭 Phase 1 Firefox（SIGTERM 保存 session/cookie）..."
                kill -15 "$PID" 2>/dev/null || true
                sleep 5
                kill -9 "$PID" 2>/dev/null || true

                # 等 cookies.sqlite 落盘
                local wait_cookie=0
                while [ $wait_cookie -lt 10 ]; do
                    if [ -f "$PROFILE/cookies.sqlite" ]; then
                        local cf_count
                        cf_count=$(sqlite3 "$PROFILE/cookies.sqlite" \
                            "SELECT COUNT(*) FROM moz_cookies WHERE name='cf_clearance' AND expiry > strftime('%s','now')" \
                            2>/dev/null || echo 0)
                        if [ "$cf_count" -gt 0 ]; then
                            echo "  ✅ Cookie 已落盘 ($cf_count 条 cf_clearance)"
                            clear_locks
                            return 0
                        fi
                    fi
                    sleep 1
                    wait_cookie=$((wait_cookie + 1))
                done

                # 没 cf_clearance 也继续（可能不需要 CF）
                clear_locks
                echo "  ⚠️  无 cf_clearance cookie（可能不需要 CF / 验证未完成）"
                return 0
            fi
        fi

        if [ $elapsed -gt $PHASE1_TIMEOUT ]; then
            echo "⏰ Phase 1 超时 (${PHASE1_TIMEOUT}s) — 强制进入 Phase 2"
            kill -9 "$PID" 2>/dev/null || true
            break
        fi
    done

    clear_locks
    echo "  ✅ Phase 1 Firefox 已退出"
}

# ═══════════════════════════════════════════════════════════════════════
# Phase 2 — StreamDumper 抓取（sandbox 关闭 + 智能监控）
# ═══════════════════════════════════════════════════════════════════════
phase2() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  Phase 2 — StreamDumper 抓取                              ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    # 关 sandbox（StreamDumper 写 /tmp 需要）
    local PJS="$PROFILE/prefs.js"
    if [ -f "$PJS" ]; then
        sed -i '/user_pref("security\.sandbox/d' "$PJS" 2>/dev/null || true
    fi
    cat >> "$PJS" << 'EP'
// === Phase 2: 关 sandbox 让 StreamDumper 写盘 ===
user_pref("security.sandbox.content.level", 0);
user_pref("security.sandbox.gmp.level", 0);
user_pref("security.sandbox.rdd.level", 0);
user_pref("security.sandbox.socket.level", 0);
user_pref("security.sandbox.utility.level", 0);
EP

    clear_locks
    _apply_proxy_env

    local out_base=$(OUT_BASE)
    local DUMP_FILE="${out_base}.h264"
    local AUDIO_DUMP="${out_base}.aac"
    local SIDECAR="${out_base}.sidecar.json"

    echo "📦 Video dump: $DUMP_FILE"
    echo "📦 Audio dump: $AUDIO_DUMP"
    echo "📋 Sidecar:    $SIDECAR"
    if has_proxy_env; then
        echo "🌐 代理: 环境变量 $(env | grep -iE '^(http|https|all|socks)_proxy=' | tr '\n' ' ')"
    else
        echo "🌐 代理: 直联（无 *proxy 环境变量）"
    fi
    echo ""

    # 加载 lib-sidecar + lib-monitor
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib-sidecar.sh"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib-monitor.sh"

    # Phase 2 URL 优先级：起始传入 > profile 中保存的 session tab
    local PHASE2_URL="${URL:-about:home}"

    local monitor_result
    monitor_result=$(monitor_run "$FF" "$PROFILE" "$PHASE2_URL" \
        "$DUMP_FILE" "$AUDIO_DUMP" "$SIDECAR" 2>>"$LOG")

    echo "$monitor_result"
    local reason interrupt final_video final_audio
    IFS='|' read -r reason interrupt final_video final_audio <<< "$monitor_result"

    DUMP_FILE="$final_video"
    AUDIO_DUMP="$final_audio"

    case "$reason" in
        ended)             echo "  ✅ 视频正常结束（<video>.ended）";;
        stall_limit)       echo "  📦 流停滞兜底结束";;
        paused_too_long)   echo "  ⏸️  长时间暂停";;
        max_interrupts)    echo "  ❌ 崩溃恢复次数达到上限";;
        *)                 echo "  ⚠️  reason=$reason";;
    esac
    if [ "$interrupt" -gt 0 ]; then
        echo "  🔄 期间中断 $interrupt 次后恢复"
    fi

    # 合成 mp4
    if [ -s "$DUMP_FILE" ] || [ -s "$AUDIO_DUMP" ]; then
        mux_to_mp4 "$DUMP_FILE" "$AUDIO_DUMP" "${out_base}.mp4"
    else
        echo "  ⚠️  Phase 2 无 dump 文件（视频可能未进入播放）"
        return 1
    fi

    # auto-next 占位提示
    if [ "$AUTO_NEXT" -eq 1 ]; then
        echo ""
        echo "  ℹ️  --auto-next 模式已置位，但 monitor 切集检测在 v3.1 才实现。"
        echo "     当前将只产出第一集 mp4。如需 playlist 全抓，可多次运行（每换 URL）"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# mp4 封装（含分段 concat + AAC 双轨）
# ═══════════════════════════════════════════════════════════════════════
mux_to_mp4() {
    local dump="$1" audio="$2" out="$3"
    local base="${dump%.h264}"

    echo "🎬 封装 → $out"

    # 检测多段
    local parts
    parts=$(ls "${base}".p*.h264 2>/dev/null | sort)

    local tmp_v="${out}.tmpv.mp4"
    if [ -n "$parts" ]; then
        echo "  (多段合并: $(echo "$parts" | wc -l) 段)"
        local concat_file="${base}.concat.txt"
        : > "$concat_file"
        for p in $parts; do echo "file '$p'" >> "$concat_file"; done
        ffmpeg -y -f concat -safe 0 -i "$concat_file" -c copy "$tmp_v" -loglevel error || {
            rm -f "$concat_file"; return 1; }
        rm -f "$concat_file"
    elif [ -s "$dump" ]; then
        ffmpeg -y -framerate 15 -i "$dump" -c:v copy -movflags +faststart "$tmp_v" -loglevel error || return 1
    fi

    if [ ! -f "$tmp_v" ]; then
        echo "  ⚠️  无视频 dump，跳过封装"
        return 1
    fi

    # 合并音频
    if [ -s "$audio" ]; then
        ffmpeg -y -i "$tmp_v" -i "$audio" \
            -c copy -map 0:v:0 -map 1:a:0 \
            -movflags +faststart "$out" -loglevel error || {
            echo "  ⚠️  音频合并失败，留视频轨"; mv "$tmp_v" "$out"; return 1; }
        rm -f "$tmp_v"
    else
        mv "$tmp_v" "$out"
    fi

    echo "  ✅ mp4: $out"
    ls -lh "$out"
    ffprobe -v error -show_entries format=duration:stream=codec_name,width,height \
        -of default=nw=1 "$out" 2>/dev/null | sed 's/^/    /' | head -8
}

# ═══════════════════════════════════════════════════════════════════════
# 主循环
# ═════════════════════════════════════════════════

main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  firefox-stream-fetch v3.0                                ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo "  URL:           ${URL:-（空白页，手动输入）}"
    echo "  Profile:       $PROFILE"
    echo "  Output:        $OUTPUT_DIR"
    echo "  Auto-next:     $([ $AUTO_NEXT -eq 1 ] && echo '✅' || echo '❌')"
    echo ""

    local phase2_ret=0
    local episode=1
    while true; do
        if [ $SKIP_PHASE1 -eq 0 ]; then
            phase1 || { echo "❌ Phase 1 失败"; return 1; }
        fi
        phase2 || phase2_ret=$?
        
        # --- auto-next: 检查 sidecar 是否有 next_url ---
        if [ $AUTO_NEXT -eq 1 ]; then
            local sidecar
            sidecar=$(ls -t "$OUTPUT_DIR"/${BASE_NAME}-*.sidecar.json 2>/dev/null | head -1)
            if [ -n "$sidecar" ] && [ -f "$sidecar" ]; then
                local next_url
                next_url=$(jq -r '.next_url // empty' "$sidecar" 2>/dev/null)
                if [ -n "$next_url" ] && [ "$next_url" != "null" ]; then
                    echo ""
                    echo "═══════════════════════════════════════════════════════"
                    echo "  ⏭️  自动切下一集: $next_url"
                    echo "═══════════════════════════════════════════════════════"
                    URL="$next_url"
                    episode=$((episode + 1))
                    continue
                fi
            fi
        fi
        break
    done

    # 清理（除非 --keep-h264）
    if [ $KEEP_H264 -eq 0 ]; then
        echo ""
        echo "🧹 清理中间文件..."
        find "$OUTPUT_DIR" -name "${BASE_NAME}-*" ! -name "*.mp4" ! -name "*.log" ! -name "*.sidecar.json" -delete 2>/dev/null || true
        echo "  ✅ (保留 mp4 + log + sidecar)"
    fi

    echo ""
    echo "🏁 任务结束。"
    echo "📂 输出目录: $OUTPUT_DIR"
    ls -lh "$OUTPUT_DIR"/${BASE_NAME}*.mp4 2>/dev/null | head -5
}

main "$@"══════════════════════