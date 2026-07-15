#!/bin/bash
# firefox-stream-fetch v2.0.0 — 通用视频抓取脚本
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
#      轮询窗口标题检测"播放开始"（标题从 CM 变为实际视频标题）
#      → SIGTERM 保存 session → 进入 Phase 2
#
#   2. Phase 2: sandbox 关闭 + session restore
#      → 恢复上一阶段标签页 → cookie 复用 → 视频播放 → StreamDumper 写 dump
#
#   3. 监控循环：dump 增长、停止、切集（--auto-next）、结束
#   4. 后处理：ffmpeg 转 .mp4、删除 .h264
# ═══════════════════════════════════════════════════════════════════════
set -e

PROJECT="/home/wangyc/Documents/软件类工作/firefox-stream-fetch"
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
        http://*|https://*) URL="$1"; shift;;
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
echo "║  firefox-stream-fetch 通用抓取脚本 v2                      ║"
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
    XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
        xdotool search --name "Nightly\|Firefox" 2>/dev/null | head -1
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
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY MOZ_STREAM_DUMP_PATH

    echo "🚀 启动 Firefox（Phase 1：sandbox 默认，$PHASE1_START）..."
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
    echo "│  需要 CF 验证时手动通过。脚本自动检测播放开始" 
    echo "│  然后关闭 Firefox 进入 Phase 2 抓取"
    echo "└──────────────────────────────────────────────────────────┘"
    echo ""

    # 轮询等待：标题变化（CF 通过）或 Firefox 退出
    local elapsed=0 saw_cf=0
    while kill -0 "$PID" 2>/dev/null; do
        sleep 2
        elapsed=$((elapsed + 2))
        local title=$(get_firefox_title "$WID")
        if [ -n "$title" ]; then
            if echo "$title" | grep -qi "Just a moment"; then
                [ $saw_cf -eq 0 ] && echo "  ⏳ CF 挑战中..." && saw_cf=1
            elif ! echo "$title" | grep -qiE "Nightly|New Tab|Firefox"; then
                echo "  ✅ 检测到播放开始（标题：'$title'）"
                echo "  🔪 关闭 Phase 1 Firefox（SIGTERM 保存 session）..."
                kill -15 "$PID" 2>/dev/null || true
                sleep 5
                kill -9 "$PID" 2>/dev/null || true
                kill_profile_firefox
                return 0
            fi
        fi
        if [ $elapsed -gt $PHASE1_TIMEOUT ]; then
            echo "⏰ 超时"
            kill -9 "$PID" 2>/dev/null || true
            break
        fi
    done
    echo "  ✅ Phase 1 Firefox 已退出"
}

# ─────────────────────────────────────────────────────────────
# Phase 2: StreamDumper 抓取（sandbox 关闭，session restore）
# ─────────────────────────────────────────────────────────────
phase2() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  Phase 2 — StreamDumper 抓取（sandbox 关闭）              ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    # 关 sandbox
    local PJS="$PROFILE/prefs.js"
    [ -f "$PJS" ] && sed -i '/user_pref("security\.sandbox/d' "$PJS" 2>/dev/null || true
    cat >> "$PJS" <<'EP'
user_pref("security.sandbox.content.level", 0);
user_pref("security.sandbox.gmp.level", 0);
user_pref("security.sandbox.rdd.level", 0);
user_pref("security.sandbox.socket.level", 0);
user_pref("security.sandbox.utility.level", 0);
EP

    clear_locks
    export MOZ_STREAM_DUMP_PATH="$DUMP_FILE"
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY

    echo "📦 Dump: $DUMP_FILE"
    echo "🚀 启动 Firefox（Phase 2：sandbox 关闭，session restore）..."
    echo "  （如果传了 URL 用它打开，否则恢复上一阶段的 session）"

    local START_PAGE="${URL:-$PROFILE_NAME}"
    # 有 URL 时直接打开，无 URL 时靠 about:sessionrestore 或默认页
    setsid nohup "$FF" \
        -profile "$PROFILE" \
        -no-remote --new-instance \
        "${URL}" \
        < /dev/null >> "$LOG" 2>&1 &
    PHASE2_PID=$!
    disown

    pull_window_front
    local WID=$(get_firefox_wid)

    # 监控 dump
    echo ""
    echo "  ⏳ 监控 dump（每 5 秒，$DONE_STALL 秒无增长 = 结束）..."

    local last_size=0 stall_count=0 dump_started=0 prev_title=""
    while kill -0 "$PHASE2_PID" 2>/dev/null; do
        sleep 5

        # 标题变化检测（切集）
        local title=$(get_firefox_title "$WID")
        if [ -n "$title" ] && [ -n "$prev_title" ] && [ "$title" != "$prev_title" ]; then
            echo "  🔄 标题变化：'$prev_title' → '$title'（可能切集）"
            prev_title="$title"
        fi

        # dump 增长
        if [ -f "$DUMP_FILE" ]; then
            local size=$(stat -c%s "$DUMP_FILE")
            if [ "$size" -gt "$last_size" ]; then
                local delta=$((size - last_size))
                echo "  ✅ [${EPISODE_INDEX}] $(numfmt --to=iec $size)  (+$(numfmt --to=iec $delta))"
                last_size=$size
                stall_count=0
                dump_started=1
            else
                stall_count=$((stall_count+1))
                if [ $stall_count -ge $((DONE_STALL/5)) ]; then
                    echo "  📦 ${DONE_STALL}s 无增长"
                    break
                fi
            fi
        else
            echo "  ⏳ 暂无 dump"
        fi
    done

    if [ $dump_started -eq 0 ]; then
        echo "  ⚠️  Phase 2 无 dump"
    fi
}

# ─────────────────────────────────────────────────────────────
# 转 mp4 + 清理
# ─────────────────────────────────────────────────────────────
mux_to_mp4() {
    local dump="$1" label="${2:-}"
    local out="${dump%.h264}.mp4"
    echo "📦 [$label] 转 mp4: $out"
    if ffmpeg -y -framerate $FRAMERATE -i "$dump" -c:v copy -movflags +faststart "$out" 2>&1 | tail -3; then
        ls -lh "$out"
        [ $CLEANUP -eq 1 ] && rm -f "$dump" && echo "  🧹 删 .h264"
        echo "$out"
        return 0
    fi
    echo "  ❌ mp4 失败，保留 .h264"
    return 1
}

# ─────────────────────────────────────────────────────────────
# 主流程
# ─────────────────────────────────────────────────────────────
EPISODE_FILES=()
kill_profile_firefox

if has_valid_cf_cookie; then
    echo "✅ 有效 cf_clearance cookie，跳过 Phase 1"
else
    phase1
    kill_profile_firefox
    if ! has_valid_cf_cookie; then
        echo "❌ 无 cf_clearance cookie（可能未过 CF）"
        exit 1
    fi
    echo "✅ Phase 1 完成"
fi

phase2

# 转 mp4
mp4=$(mux_to_mp4 "$DUMP_FILE" "第 1 集")
[ -n "$mp4" ] && EPISODE_FILES+=("$mp4")

# 多集（--auto-next）
if [ $AUTO_NEXT -eq 1 ]; then
    EPISODE_INDEX=2
    while true; do
        EP_DUMP="$OUTPUT_DIR/${PROFILE_NAME}-${TS}-ep${EPISODE_INDEX}.h264"
        echo ""
        echo "🔄 尝试第 $EPISODE_INDEX 集（$NEXT_STALL 秒检测）..."
        export MOZ_STREAM_DUMP_PATH="$EP_DUMP"
        clear_locks
        # 需要 URL 重启，或者用 session restore
        setsid nohup "$FF" -profile "$PROFILE" -no-remote --new-instance "${URL}" \
            < /dev/null >> "$LOG" 2>&1 &
        PHASE2_PID=$!
        disown

        local waited=0
        while [ $waited -lt $NEXT_STALL ]; do
            sleep 5; waited=$((waited+5))
            if [ -f "$EP_DUMP" ] && [ $(stat -c%s "$EP_DUMP" 2>/dev/null || echo 0) -gt 5000 ]; then
                echo "  ✅ 新集开始"
                break
            fi
        done
        if [ $waited -ge $NEXT_STALL ]; then
            echo "  ⏰ $NEXT_STALL 秒无新内容，停止"
            kill_profile_firefox
            break
        fi

        DUMP_FILE="$EP_DUMP"
        phase2
        mp4=$(mux_to_mp4 "$DUMP_FILE" "第 $EPISODE_INDEX 集")
        [ -n "$mp4" ] && EPISODE_FILES+=("$mp4")
        EPISODE_INDEX=$((EPISODE_INDEX+1))
    done
fi

# 最终结果
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  完成  ${#EPISODE_FILES[@]} 集"
echo "════════════════════════════════════════════════════════════"
for f in "${EPISODE_FILES[@]}"; do
    ls -lh "$f"
    ffprobe -v error -show_format -show_streams "$f" 2>&1 \
        | grep -E "codec_name|profile|width|height|duration=|nb_frames" | head -6 | sed 's/^/  /'
    echo ""
done
ls -lh "$LOG"
echo "💡 ffplay '${EPISODE_FILES[0]}'"
