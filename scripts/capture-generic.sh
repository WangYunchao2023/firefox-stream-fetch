#!/bin/bash
# firefox-stream-fetch v2.1.0 — 通用视频抓取脚本（集成智能监控）
#
# ═══════════════════════════════════════════════════════════════════════
# 用法
# ═══════════════════════════════════════════════════════════════════════
#   ./capture-generic.sh [URL] [PROFILE_NAME] [OPTIONS]
#
#   URL          - 可选，视频页 URL。
#                  不填时 Phase 1 开空白页，用户在 Firefox 中手动输入
#                  并通过 session restore 带给 Phase 2
#   PROFILE_NAME - 可选，profile 名
#
#   OPTIONS:
#     --output DIR          保存目录（默认：~/Videos/firefox抓取/）
#     --auto-next           启用自动连集抓取（默认：关闭）
#     --framerate N         mp4 帧率（默认：15）
#     --next-stall N        切集等待秒数（默认：30s）
#     --done-stall N        播放结束判定秒数（默认：120s）
#     --no-cleanup          保留 .h264 中间文件
#     --help                帮助
#
# 例子:
#   ./capture-generic.sh                                              # 空白页，手动输 URL
#   ./capture-generic.sh https://www.yfsp.tv/play/zImbBGABDR2
#   ./capture-generic.sh https://example.com/video --output /data/ --auto-next
#
# ═══════════════════════════════════════════════════════════════════════
# 流程
# ═══════════════════════════════════════════════════════════════════════
#   1. Phase 1: sandbox 默认启动 Firefox（空白页或指定 URL）
#      BiDi 检测视频播放开始 → SIGTERM 保存 session → 进入 Phase 2
#
#   2. Phase 2: sandbox 关闭 + session restore（用 lib-monitor 智能监控）
#      → 恢复上一阶段标签页 → cookie 复用 → 视频播放 → StreamDumper 写 dump
#      → 每 5s 通过 BiDi 查 video 状态（playing/paused/buffering/ended）
#      → 分场景 stall 累计（paused 不计、buffering 减半）
#      → firefox 崩溃时自动重启 + seek 到 last_keyframe_pts 续接
#      → video.ended / stall_limit / paused_too_long 触发结束
#
#   3. 监控循环：dump 增长、停止、切集（--auto-next）、结束
#   4. 后处理：ffmpeg 转 .mp4（多段 concat）、删除 .h264
# ═══════════════════════════════════════════════════════════════════════
set -e

PROJECT="/home/wangyc/Documents/软件类工作/firefox-stream-fetch"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FF=$(find -L "$PROJECT/obj-stream" -path "*dist/bin/firefox" -type f -executable 2>/dev/null | head -1)
[ -z "$FF" ] && { echo "❌ 找不到 firefox"; exit 1; }

# ─────────────────────────────────────────────────────────────
# 解析参数
# ─────────────────────────────────────────────────────────────
OUTPUT_DIR="$HOME/Videos/firefox抓取"
AUTO_NEXT=0
FRAMERATE=15
NEXT_STALL=30
DONE_STALL=120
CLEANUP=1
URL=""
PROFILE_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)       OUTPUT_DIR="$2"; shift 2;;
        --auto-next)    AUTO_NEXT=1; shift;;
        --framerate)    FRAMERATE="$2"; shift 2;;
        --next-stall)   NEXT_STALL="$2"; shift 2;;
        --done-stall)   DONE_STALL="$2"; shift 2;;
        --no-cleanup)   CLEANUP=0; shift;;
        --help|-h)      cat <<HELP
用法: $0 [URL] [PROFILE_NAME] [OPTIONS]
URL          可选，视频 URL
PROFILE_NAME 可选，profile 名
--output DIR   保存目录（默认: $OUTPUT_DIR）
--auto-next    自动连集（默认: 关）
--framerate N  mp4 帧率（默认: 15）
--no-cleanup   保留 .h264
例子:
  $0                                              # 空白页开启，手动输 URL
  $0 https://www.yfsp.tv/play/zImbBGABDR2
  $0 https://example.com/video --output /data/ --auto-next
HELP
exit 0;;
        http://*|https://*|file://*) URL="$1"; shift;;
        --*)            echo "未知参数: $1"; exit 1;;
        *)              [ -z "$PROFILE_NAME" ] && PROFILE_NAME="$1" || POSITIONAL+=("$1"); shift;;
    esac
done

if [ -z "$PROFILE_NAME" ]; then
    if [ -n "$URL" ]; then
        DOMAIN=$(echo "$URL" | sed -E 's|^https?://||; s|/.*$||; s|^www\.||')
        PROFILE_NAME=$(echo "$DOMAIN" | tr -cd 'a-zA-Z0-9_')
    else
        PROFILE_NAME="manual-$(date +%Y%m%d-%H%M%S)"
    fi
    if [ ${#PROFILE_NAME} -lt 3 ]; then
        PROFILE_NAME="profile-$(echo -n "$URL" | md5sum | cut -c1-8)"
    fi
fi
PROFILE="/tmp/firefox-stream-$PROFILE_NAME"

mkdir -p "$OUTPUT_DIR"
[ ! -d "$OUTPUT_DIR" ] && { echo "❌ 无法创建 $OUTPUT_DIR"; exit 1; }

TS=$(date +%Y%m%d-%H%M%S)
DUMP_FILE="$OUTPUT_DIR/${PROFILE_NAME}-${TS}.h264"
LOG="$OUTPUT_DIR/${PROFILE_NAME}-${TS}.log"
> "$LOG"

export DISPLAY=:1
export XAUTHORITY=/run/user/1000/gdm/Xauthority
export MOZ_ENABLE_WAYLAND=0
export GDK_BACKEND=x11
PHASE1_TIMEOUT=1800
EPISODE_INDEX=1
PHASE1_START="${URL:-about:newtab}"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  firefox-stream-fetch 通用抓取脚本 v2.1                    ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "  URL:           ${URL:-"（空白页，手动输入）"}"
echo "  Profile:       $PROFILE"
echo "  Output:        $OUTPUT_DIR"
echo "  Auto-next:     $([ $AUTO_NEXT -eq 1 ] && echo '✅' || echo '❌')"
echo "  Framerate:     $FRAMERATE fps"
echo "  Cleanup:       $([ $CLEANUP -eq 1 ] && echo '✅' || echo '❌')"
echo ""

# ─────────────────────────────────────────────────────────────
# 公共函数
# ─────────────────────────────────────────────────────────────
clear_locks() {
    rm -f "$PROFILE/.parentlock" "$PROFILE/parent.lock" "$PROFILE/lock"
}

kill_profile_firefox() {
    # SIGTERM 优雅退出（让 Firefox 保存 session），再 SIGKILL
    for PID in $(ps -ef | grep -v grep | grep "$PROFILE" | awk '{print $2}'); do
        kill -15 "$PID" 2>/dev/null || true
    done
    sleep 5  # 等 Firefox 存 session
    for PID in $(ps -ef | grep -v grep | grep "$PROFILE" | awk '{print $2}'); do
        EXE=$(readlink -f /proc/$PID/exe 2>/dev/null)
        CMD=$(cat /proc/$PID/cmdline 2>/dev/null | tr '\0' ' ')
        if echo "$EXE" | grep -q "firefox-stream-fetch" && echo "$CMD" | grep -q "$PROFILE "; then
            kill -9 "$PID" 2>/dev/null || true
        fi
    done
    sleep 2
    clear_locks
}

get_firefox_wid() {
    # 优先找带 "Nightly" 的窗口（标签页标题会含 Nightly）
    # 避免选到 URL 栏/搜索框等没标题的子窗口
    XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
        xdotool search --name "Nightly" 2>/dev/null | head -1
    # 如果没找到，找 firefox-default classname 的窗口
}

get_firefox_title() {
    local WID="$1"
    [ -n "$WID" ] && XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
        xdotool getwindowname "$WID" 2>/dev/null
}

pull_window_front() {
    local WID
    sleep 3
    for i in 1 2 3 4 5 6 7 8; do
        WID=$(get_firefox_wid)
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

has_valid_cf_cookie() {
    if [ ! -f "$PROFILE/cookies.sqlite" ]; then return 1; fi
    local count
    count=$(sqlite3 "$PROFILE/cookies.sqlite" \
        "SELECT COUNT(*) FROM moz_cookies 
         WHERE name='cf_clearance' AND expiry > strftime('%s','now')" 2>/dev/null || echo 0)
    [ "$count" -gt 0 ]
}

# ─────────────────────────────────────────────────────────────
# Phase 1: 拿 CF cookie（sandbox 正常）
# ─────────────────────────────────────────────────────────────
phase1() {
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  Phase 1 — 获取 cf_clearance（sandbox 正常）              ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    rm -rf "$PROFILE"
    mkdir -p "$PROFILE"
    cat > "$PROFILE/user.js" << PJEOF
user_pref("network.proxy.type", 5);
user_pref("media.autoplay.default", 0);
user_pref("browser.startup.page", 3);                          // 恢复上次 session
user_pref("browser.sessionstore.resume_from_crash", true);     // 允许恢复崩溃
user_pref("browser.sessionstore.max_resumed_crashes", 1);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.shell.skipDefaultBrowserCheckOnFirstRun", true);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.messaging-system.whatsNewPanel.enabled", false);
user_pref("dom.webdriver.enabled", false);
user_pref("privacy.resistFingerprinting", false);
PJEOF

    clear_locks
    export MOZ_STREAM_DUMP_PATH="/dev/null"
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY

    echo "🚀 启动 Firefox（Phase 1：sandbox 默认 + 不开 BiDi，避免 CF 检出调试端口）..."
    # **关键：Phase 1 不开 -remote-debugging-port**
    # CF Turnstile 会检测 devtools-protocol 端口作为 bot 信号
    setsid nohup "$FF" \
        -profile "$PROFILE" \
        -no-remote --new-instance \
        "$PHASE1_START" \
        < /dev/null > "$LOG" 2>&1 &
    local PID=$!
    disown

    pull_window_front
    local WID=$(get_firefox_wid)

    echo ""
    echo "┌──────────────────────────────────────────────────────────┐"
    echo "│  👆  浏览器已打开                                        │"
    [ -n "$URL" ] && echo "│  URL: $URL" || echo "│  请在 Firefox 地址栏输入 URL"
    echo "│"
    echo "│  需要 CF 验证时手动通过。脚本通过窗口标题检测视频页面加载" 
    echo "│  然后关闭 Firefox 进入 Phase 2 抓取"
    echo "└──────────────────────────────────────────────────────────┘"
    echo ""

    # **Phase 1 检测播放开始：X11 窗口标题检测（纯本地，不开 BiDi）**
    echo "  🔍 通过窗口标题检测视频页面加载（每 3s）..."
    local saw_cf=0
    local elapsed=0
    while kill -0 "$PID" 2>/dev/null; do
        sleep 3
        elapsed=$((elapsed + 3))
        local title
        title=$(get_firefox_title "$WID")
        if [ -n "$title" ]; then
            if echo "$title" | grep -qi "Just a moment"; then
                [ $saw_cf -eq 0 ] && echo "  [$elapsed s] ⏳ CF 挑战中..." && saw_cf=1
            elif [[ "$title" != "Nightly" && "$title" != "Firefox" && "$title" != "New Tab" && "$title" != "about:home" && "$title" != "about:newtab" ]]; then
                echo "  ✅ [$elapsed s] 检测到页面加载完成（标题: '$title'）"
                echo "  🔪 关闭 Phase 1 Firefox（SIGTERM 保存 session）..."
                kill -15 "$PID" 2>/dev/null || true
                sleep 5
                kill -9 "$PID" 2>/dev/null || true
                kill_profile_firefox
                # 等待 cookie.sqlite 落盘
                echo "  ⏳ 等待 cookie.sqlite 落盘..."
                local wait_cookie=0
                while [ $wait_cookie -lt 10 ]; do
                    if [ -f "$PROFILE/cookies.sqlite" ]; then
                        local cf_count
                        cf_count=$(sqlite3 "$PROFILE/cookies.sqlite" \
                            "SELECT COUNT(*) FROM moz_cookies WHERE name='cf_clearance' AND expiry > strftime('%s','now')" 2>/dev/null || echo 0)
                        if [ "$cf_count" -gt 0 ]; then
                            echo "  ✅ Cookie 已落盘 ($cf_count 条 cf_clearance)"
                            return 0
                        fi
                    fi
                    sleep 1
                    wait_cookie=$((wait_cookie + 1))
                done
                echo "  ⚠️  等待 cookie 落盘超时（CF 可能还没过或网站不需要 CF）"
                return 0
            fi
        fi
        if [ $elapsed -gt $PHASE1_TIMEOUT ]; then
            echo "⏰ Phase 1 超时 (${PHASE1_TIMEOUT}s)"
            kill -9 "$PID" 2>/dev/null || true
            break
        fi
    done
    
    # Fallback - 如果有用户传的 URL 但浏览器已退出且没检出标题，也继续 Phase 2
    echo "  ✅ Phase 1 Firefox 已退出"
        
}

# ─────────────────────────────────────────────────────────────
phase2() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  Phase 2 — StreamDumper 抓取（sandbox 关闭 + 智能监控）  ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    # 关 sandbox（monitor 启动 firefox 前生效）
    # 写入 user.js（优先级高、不被覆盖）
    cat > "$PROFILE/user.js" <<'EP'
user_pref("network.proxy.type", 5);
user_pref("media.autoplay.default", 0);
user_pref("browser.startup.page", 3);
user_pref("browser.sessionstore.resume_from_crash", true);
user_pref("browser.sessionstore.max_resumed_crashes", 1);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.shell.skipDefaultBrowserCheckOnFirstRun", true);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.messaging-system.whatsNewPanel.enabled", false);
user_pref("dom.webdriver.enabled", false);
user_pref("privacy.resistFingerprinting", false);
user_pref("security.sandbox.content.level", 0);
user_pref("security.sandbox.gmp.level", 0);
user_pref("security.sandbox.rdd.level", 0);
user_pref("security.sandbox.socket.level", 0);
user_pref("security.sandbox.utility.level", 0);
user_pref("security.sandbox.file.level", 0);
EP

    clear_locks
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY

    # 准备路径
    local SIDECAR="$OUTPUT_DIR/${PROFILE_NAME}-${TS}.sidecar.json"
    local AUDIO_DUMP="${DUMP_FILE%.h264}.aac"
    # Phase2 URL 优先级：Phase1 保存的 URL > 原始 URL 参数 > about:home
    local PHASE2_URL="about:home"
    if [ -n "${URL:-}" ]; then
        PHASE2_URL="$URL"
    elif [ -n "${PHASE1_URL_FILE:-}" ] && [ -s "$PHASE1_URL_FILE" ]; then
        PHASE2_URL="$(cat "$PHASE1_URL_FILE" 2>/dev/null || echo '')"
        if [ -n "$PHASE2_URL" ]; then
            echo "  📎 Phase2 从 Phase1 续接 URL: $PHASE2_URL"
        else
            PHASE2_URL="about:home"
        fi
    fi

    echo "📦 Video dump: $DUMP_FILE"
    echo "📦 Audio dump: $AUDIO_DUMP"
    echo "📋 Sidecar:    $SIDECAR"
    echo "🚀 启动 Firefox + lib-monitor 智能监控..."
    echo "   （每 5s 通过 BiDi 查询 video 状态，崩溃自动恢复最多 3 次）"

    # 加载 lib-monitor
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib-sidecar.sh"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib-monitor.sh"

    # 收集 monitor log：stdout 进 monitor_result（关键返回），stderr 进 stderr.log
    local STDERR_LOG="${DUMP_FILE%.h264}.monitor.log"
    exec 4>>"$LOG"

    local monitor_result
    monitor_result=$(monitor_run "$FF" "$PROFILE" "$PHASE2_URL" \
        "$DUMP_FILE" "$AUDIO_DUMP" "$SIDECAR" \
        2> >(tee "$STDERR_LOG" >>"$LOG" >&2))

    echo "$monitor_result"
    local reason interrupt final_video final_audio
    IFS='|' read -r reason interrupt final_video final_audio <<< "$monitor_result"

    DUMP_FILE="$final_video"
    AUDIO_DUMP="$final_audio"

    case "$reason" in
        ended)             echo "  ✅ video.ended（点播完成）";;
        stall_limit)       echo "  📦 stall_limit 兜底结束";;
        paused_too_long)   echo "  ⏸️  paused 超时结束";;
        max_interrupts)    echo "  ❌ 重启上限（interrupts=$interrupt）";;
        *)                 echo "  ⚠️  reason=$reason";;
    esac

    if [ "$interrupt" -gt 0 ]; then
        echo "  🔄 中断 $interrupt 次后恢复完成"
    fi

    # dump_started 检查
    local size
    size=$(stat -c%s "$DUMP_FILE" 2>/dev/null || echo 0)
    if [ "$size" -gt 0 ]; then
        dump_started=1
        # 检查有没有多段
        local base="${DUMP_FILE%.h264}"
        local parth
        parth=$(ls "${base}".p*.h264 2>/dev/null | sort)
        if [ -n "$parth" ]; then
            echo "  📦 检测到分段 dump（$(echo "$parth" | wc -l) 段）"
        fi
    else
        echo "  ⚠️  Phase 2 无 dump"
    fi
}

# ─────────────────────────────────────────────────────────────
# 转 mp4 + 清理
# ─────────────────────────────────────────────────────────────
mux_to_mp4() {
    local dump="$1" label="${2:-}"
    local out="${dump%.h264}.mp4"
    local base="${dump%.h264}"

    # 检测多段
    local parts
    parts=$(ls "${base}".p*.h264 2>/dev/null | sort)
    
    echo "🎬 开始封装 $dump -> $out ..."
    if [ -n "$parts" ]; then
        echo "  (多段合并模式)"
        local concat_file="${base}.concat.txt"
        echo "file '${base}.p0.h264'" > "$concat_file"
        local count=$(echo "$parts" | wc -l)
        for ((i=1; i<count; i++)); do
            echo "file '$(echo "$parts" | sed -n "$((i+1))p")'" >> "$concat_file"
        done
        ffmpeg -y -f concat -safe 0 -i "$concat_file" -c copy "$out" -loglevel error
        rm "$concat_file"
    else
        ffmpeg -y -i "$dump" -c copy "$out" -loglevel error
    fi

    # 合并音频
    local audio="${dump%.h264}.aac"
    if [ -f "$audio" ]; then
        echo "  (合并音频 $audio)"
        ffmpeg -y -i "$out" -i "$audio" -c copy -map 0:v:0 -map 1:a:0 "$out.tmp" -loglevel error
        mv "$out.tmp" "$out"
    fi

    if [ $? -eq 0 ]; then
        echo "  ✅ 封装成功: $out"
    else
        echo "  ❌ 封装失败"
    fi
}

cleanup() {
    echo "🧹 开始清理中间文件..."
    if [ "$CLEANUP" -eq 1 ]; then
        find "$OUTPUT_DIR" -name "${PROFILE_NAME}-${TS}.*" ! -name "*.mp4" ! -name "*.log" ! -name "*.sidecar.json" -delete
        echo "  ✅ 已删除中间文件"
    else
        echo "  ℹ️  跳过清理 (已保留 .h264)"
    fi
}

# ─────────────────────────────────────────────────────────────
# 主循环
# ─────────────────────────────────────────────────────────────
main() {
    phase1 || { echo "❌ Phase 1 失败"; exit 1; }
    phase2 || { echo "❌ Phase 2 失败"; exit 1; }
    
    if [ -s "$DUMP_FILE" ]; then
        mux_to_mp4 "$DUMP_FILE"
    else
        echo "⚠️  没有可用的 dump 文件进行封装"
    fi

    if [ "$AUTO_NEXT" -eq 1 ]; then
        # 这里简单处理：如果 URL 存在且需要自动下一集，可以实现更复杂的逻辑
        # 目前暂不实现复杂的下一集跳转，仅留出钩子
        echo "  ⏭️  (Auto-next 逻辑暂未在此版本实现)"
    fi

    cleanup
    # 清理 Phase1 URL 临时文件
    rm -f "${PHASE1_URL_FILE:-}" 2>/dev/null
    echo ""
    echo "🏁 任务结束。"
}

main "$@"
