#!/bin/bash
# 通用视频抓取脚本 v2 — 任何 CF Turnstile 网站都能用
#
# ═══════════════════════════════════════════════════════════════════════
# 用法
# ═══════════════════════════════════════════════════════════════════════
#   ./capture-generic.sh URL [PROFILE_NAME] [OPTIONS]
#
#   URL          - 必填，任意 HTTP(S) URL（如视频页）
#   PROFILE_NAME - 可选，profile 名（默认：基于 URL 域名自动生成）
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
#   ./capture-generic.sh https://www.yfsp.tv/play/zImbBGABDR2
#   ./capture-generic.sh https://example.com/video example --output /data/v/ --auto-next
#   ./capture-generic.sh https://example.com/video --framerate 30
#
# ═══════════════════════════════════════════════════════════════════════
# 流程
# ═══════════════════════════════════════════════════════════════════════
#   1. Phase 1: sandbox 默认启动 Firefox
#      轮询窗口标题检测"播放开始"（标题从 "Just a moment" 变为实际视频标题）
#      → 关闭 Phase 1 Firefox → 进入 Phase 2
#      兜底：Firefox 死了（WebGL 崩溃）/ 30 分钟超时
#
#   2. Phase 2: sandbox 关闭 + MOZ_STREAM_DUMP_PATH
#      启动 Firefox → cookie 复用 → 视频播放 → StreamDumper 写 dump
#
#   3. 监控循环：
#      - dump 增长 → 继续
#      - dump 停止 + Firefox 死了 + 超时 → 结束
#      - dump 停止 + Firefox 还活着 + 标题变化 → 切集 → 保存当前集 mp4
#      - --auto-next 时：切集后继续抓下一集
#
#   4. 后处理：ffmpeg 转 .mp4，删除 .h264（除非 --no-cleanup）
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

print_help() {
    cat <<HELPEOF
用法: $0 URL [PROFILE_NAME] [OPTIONS]

URL          必填，要抓取的视频页 URL
PROFILE_NAME 可选，profile 名（默认按域名生成）

OPTIONS:
    --output DIR          保存目录（默认: $OUTPUT_DIR）
    --auto-next           启用自动连集抓取
    --framerate N         mp4 帧率（默认: 15）
    --next-stall N        切集等待秒数（默认: 30）
    --done-stall N        播放结束判定秒数（默认: 120）
    --no-cleanup          保留 .h264 中间文件
    --help                显示此帮助

例子:
    $0 https://www.yfsp.tv/play/zImbBGABDR2
    $0 https://example.com/video example --output /data/v/ --auto-next
HELPEOF
    exit 0
}

# 第一个无 flag 参数是 URL
i=1
for arg in "$@"; do
    case "$arg" in
        --output)        i=$((i+1)); OUTPUT_DIR="${!i}";;
        --auto-next)     AUTO_NEXT=1;;
        --framerate)     i=$((i+1)); FRAMERATE="${!i}";;
        --next-stall)    i=$((i+1)); NEXT_STALL="${!i}";;
        --done-stall)    i=$((i+1)); DONE_STALL="${!i}";;
        --no-cleanup)    CLEANUP=0;;
        --help|-h)       print_help;;
        http*|https*)    [ -z "$URL" ] && URL="$arg";;
        *)               [ -z "$PROFILE_NAME" ] && PROFILE_NAME="$arg";;
    esac
    i=$((i+1))
done

[ -z "$URL" ] && { echo "❌ URL 必填"; print_help; }

# ─────────────────────────────────────────────────────────────
# 域名 → profile 名
# ─────────────────────────────────────────────────────────────
if [ -z "$PROFILE_NAME" ]; then
    DOMAIN=$(echo "$URL" | sed -E 's|^https?://||; s|/.*$||; s|^www\.||')
    PROFILE_NAME=$(echo "$DOMAIN" | tr -cd 'a-zA-Z0-9_')
    if [ ${#PROFILE_NAME} -lt 3 ]; then
        PROFILE_NAME="profile-$(echo -n "$URL" | md5sum | cut -c1-8)"
    fi
fi
PROFILE="/tmp/firefox-stream-$PROFILE_NAME"

# 创建输出目录
mkdir -p "$OUTPUT_DIR"
[ ! -d "$OUTPUT_DIR" ] && { echo "❌ 无法创建输出目录 $OUTPUT_DIR"; exit 1; }

TS=$(date +%Y%m%d-%H%M%S)
DUMP_FILE="$OUTPUT_DIR/${PROFILE_NAME}-${TS}.h264"
LOG="$OUTPUT_DIR/${PROFILE_NAME}-${TS}.log"
> "$LOG"

export DISPLAY=:1
export XAUTHORITY=/run/user/1000/gdm/Xauthority

# Phase 1 检测"播放开始"：窗口标题不再含 "Just a moment" + 包含 URL 域名
PHASE1_DETECT_PHRASE="Just a moment"
# Phase 1 总超时（兜底用，30 分钟）
PHASE1_TIMEOUT=1800

# 集序号（用于多集）
EPISODE_INDEX=1

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  firefox-stream-fetch 通用抓取脚本 v2                      ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "  URL:           $URL"
echo "  Profile:       $PROFILE"
echo "  Output:        $OUTPUT_DIR"
echo "  Auto-next:     $([ $AUTO_NEXT -eq 1 ] && echo '✅ 开启' || echo '❌ 关闭')"
echo "  Framerate:     $FRAMERATE fps"
echo "  Cleanup:       $([ $CLEANUP -eq 1 ] && echo '✅ 自动删 .h264' || echo '❌ 保留 .h264')"
echo ""

# ─────────────────────────────────────────────────────────────
# 公共函数
# ─────────────────────────────────────────────────────────────
clear_locks() {
    rm -f "$PROFILE/.parentlock" "$PROFILE/parent.lock" "$PROFILE/lock"
}

kill_profile_firefox() {
    for PID in $(ps -ef | grep -v grep | grep "$PROFILE" | awk '{print $2}'); do
        EXE=$(readlink -f /proc/$PID/exe 2>/dev/null)
        CMD=$(cat /proc/$PID/cmdline 2>/dev/null | tr '\0' ' ')
        if echo "$EXE" | grep -q "firefox-stream-fetch" && echo "$CMD" | grep -q "$PROFILE "; then
            kill -9 "$PID" 2>/dev/null
        fi
    done
    sleep 2
    clear_locks
}

get_firefox_wid() {
    # 找主窗口的 WID
    XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
        xdotool search --name "Nightly\|Firefox" 2>/dev/null | head -1
}

get_firefox_title() {
    local WID="$1"
    if [ -n "$WID" ]; then
        XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
            xdotool getwindowname "$WID" 2>/dev/null
    fi
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

enable_sandbox_prefs() {
    local PJS="$PROFILE/prefs.js"
    [ -f "$PJS" ] && sed -i '/user_pref("security\.sandbox/d' "$PJS" 2>/dev/null || true
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
    local PJS="$PROFILE/prefs.js"
    [ -f "$PJS" ] && sed -i '/user_pref("security\.sandbox/d' "$PJS" 2>/dev/null || true
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

# Phase 1 智能等待：检测窗口标题变化
# 返回 0 = 检测到播放开始（或 Firefox 已退出），1 = 超时
phase1_wait() {
    local PHASE1_PID="$1"
    local WID="$2"
    local elapsed=0
    local prev_title=""
    local detected_playing=0

    while kill -0 "$PHASE1_PID" 2>/dev/null; do
        sleep 2
        elapsed=$((elapsed + 2))

        # 检查窗口标题
        local title=$(get_firefox_title "$WID")
        if [ -n "$title" ] && [ "$title" != "$prev_title" ]; then
            prev_title="$title"
            # 标题里包含 "Just a moment" → 还在 CF
            if echo "$title" | grep -qi "$PHASE1_DETECT_PHRASE"; then
                echo "  ⏳ 检测到 CF 挑战中..."
            # 标题里包含 URL 域名（实际视频页）→ 播放开始
            elif echo "$title" | grep -qi "$(echo "$URL" | sed -E 's|^https?://||; s|/.*$||; s|^www\.||')"; then
                echo "  ✅ 检测到播放已开始（标题：'$title'）"
                detected_playing=1
                break
            fi
        fi

        if [ $elapsed -gt $PHASE1_TIMEOUT ]; then
            echo "⏰ 等待超时"
            return 1
        fi
    done

    if [ $detected_playing -eq 1 ]; then
        # 关闭 Phase 1 Firefox（会保留 cookie，因为 cookie 已经在数据库里）
        echo "  🔪 关闭 Phase 1 Firefox（cookie 已落盘）..."
        kill -15 "$PHASE1_PID" 2>/dev/null
        sleep 2
        kill -9 "$PHASE1_PID" 2>/dev/null
        # 杀所有 child
        for CPID in $(pgrep -P "$PHASE1_PID" 2>/dev/null); do
            kill -9 "$CPID" 2>/dev/null
        done
        sleep 1
        kill_profile_firefox
        return 0
    else
        # Firefox 自己死了（WebGL 崩 或 手动关）
        echo "  ✅ Phase 1 Firefox 已退出（自动崩溃/手动关闭）"
        return 0
    fi
}

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
    local WID=$(get_firefox_wid)

    echo ""
    echo "┌──────────────────────────────────────────────────────────┐"
    echo "│  👆  浏览器已打开 URL：$URL"
    echo "│"
    echo "│  如果需要 Cloudflare 验证，请在窗口中手动通过"
    echo "│"
    echo "│  脚本会通过窗口标题自动检测'播放开始'"
    echo "│  CF 通过后立即关闭 Firefox 并进入 Phase 2"
    echo "│"
    echo "│  （兜底：Firefox WebGL 崩溃也视为 CF 通过）"
    echo "└──────────────────────────────────────────────────────────┘"
    echo ""

    phase1_wait "$PHASE1_PID" "$WID"
}

# 单集抓取 + 监控循环
# 集序号 $1, dump 文件 $2
# 返回：0 = 正常完成 / 1 = 切集中 / 2 = 异常退出
capture_one_episode() {
    local ep_index="$1"
    local dump="$2"
    local last_size=0
    local stall_count=0
    local dump_started=0
    local prev_title=""
    local WID=$(get_firefox_wid)

    while kill -0 "$PHASE2_PID" 2>/dev/null; do
        sleep 5

        # 检测标题变化（切集）
        local title=$(get_firefox_title "$WID")
        if [ -n "$title" ] && [ -n "$prev_title" ] && [ "$title" != "$prev_title" ]; then
            echo "  🔄 窗口标题变化：'$prev_title' → '$title'"
            echo "     可能是切集，等 dump 停止后保存当前集"
            prev_title="$title"
        fi

        # 检查 dump 文件
        if [ -f "$dump" ]; then
            local size=$(stat -c%s "$dump")
            if [ "$size" -gt "$last_size" ]; then
                local delta=$((size - last_size))
                echo "  ✅ [$dump] $(numfmt --to=iec $size)  (+$(numfmt --to=iec $delta))"
                last_size=$size
                stall_count=0
                dump_started=1
            else
                stall_count=$((stall_count+1))
                if [ $stall_count -ge $((DONE_STALL/5)) ]; then
                    echo "  📦 ${DONE_STALL}s 无增长，停止"
                    kill -15 "$PHASE2_PID" 2>/dev/null
                    break
                fi
            fi
        else
            echo "  ⏳ 暂无 dump（等待视频加载）"
        fi
    done

    if [ $dump_started -eq 0 ]; then
        echo "  ⚠️  Phase 2 期间无 dump"
        return 2
    fi
    return 0
}

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
}

# 转 mp4 + 清理
# 参数：dump 文件
# 返回：mp4 路径
mux_to_mp4() {
    local dump="$1"
    local out="${dump%.h264}.mp4"
    local ep_label="${2:-集}"
    echo ""
    echo "📦 [$ep_label] 转封装 mp4: $out"
    if ffmpeg -y -framerate $FRAMERATE -i "$dump" -c:v copy -movflags +faststart "$out" 2>&1 | tail -3; then
        echo "  ✅ $out"
        ls -lh "$out"
        if [ $CLEANUP -eq 1 ]; then
            rm -f "$dump"
            echo "  🧹 已清理 .h264"
        fi
        echo "$out"
        return 0
    else
        echo "  ❌ mp4 转换失败，保留 .h264 以便排查"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────
# 主流程
# ─────────────────────────────────────────────────────────────
kill_profile_firefox

# 检查 cookie
if has_valid_cf_cookie; then
    echo "✅ profile 里有有效 cf_clearance cookie，跳过 Phase 1"
    echo ""
    phase2
else
    phase1
    kill_profile_firefox
    if ! has_valid_cf_cookie; then
        echo ""
        echo "❌ 未检测到 cf_clearance cookie"
        echo "  可能原因："
        echo "  - 你没有完成 CF 验证"
        echo "  - 该网站不需要 CF，但你也没让视频播放"
        echo "  重新跑一次脚本即可再试。"
        exit 1
    fi
    echo "✅ Phase 1 完成 — cf_clearance 已落盘"
    phase2
fi

# 抓取循环
EPISODE_INDEX=1
EPISODE_FILES=()
NEXT_WAIT_COUNT=0

while true; do
    if [ $EPISODE_INDEX -gt 1 ]; then
        echo ""
        echo "🔄 准备抓取第 $EPISODE_INDEX 集..."
        # dump 文件名加 ep 后缀
        local_episode_dump="$OUTPUT_DIR/${PROFILE_NAME}-${TS}-ep${EPISODE_INDEX}.h264"
        # 重启 Firefox 用新 dump 路径
        PHASE2_PID=$(pgrep -f "$PROFILE" | head -1)
        kill -9 $PHASE2_PID 2>/dev/null
        sleep 2
        clear_locks
        export MOZ_STREAM_DUMP_PATH="$local_episode_dump"
        setsid nohup "$FF" -profile "$PROFILE" -no-remote --new-instance "$URL" \
            < /dev/null >> "$LOG" 2>&1 &
        PHASE2_PID=$!
        disown
        pull_window_front
        DUMP_FILE="$local_episode_dump"
    fi

    echo ""
    echo "📺 开始抓取第 $EPISODE_INDEX 集（dump: $DUMP_FILE）"
    capture_one_episode $EPISODE_INDEX "$DUMP_FILE"
    capture_result=$?

    if [ $capture_result -eq 2 ]; then
        echo "❌ 第 $EPISODE_INDEX 集抓取失败"
        break
    fi

    # 关闭 Firefox
    kill_profile_firefox

    # 转 mp4
    mp4_file=$(mux_to_mp4 "$DUMP_FILE" "第 $EPISODE_INDEX 集")
    if [ -n "$mp4_file" ]; then
        EPISODE_FILES+=("$mp4_file")
    fi

    # 检查是否还有下一集
    if [ $AUTO_NEXT -eq 0 ]; then
        break
    fi

    # 等 Firefox 退出干净
    sleep 2
    # 重新启动 Firefox 加载同一 URL，看是否有下一集自动播放
    setsid nohup "$FF" -profile "$PROFILE" -no-remote --new-instance "$URL" \
        < /dev/null >> "$LOG" 2>&1 &
    PHASE2_PID=$!
    disown
    pull_window_front
    echo "  ⏳ 等待下一集自动播放（$NEXT_STALL 秒）..."

    NEXT_WAIT_COUNT=0
    while [ $NEXT_WAIT_COUNT -lt $NEXT_STALL ]; do
        sleep 5
        NEXT_WAIT_COUNT=$((NEXT_WAIT_COUNT + 5))
        if [ -f "$DUMP_FILE" ]; then
            size=$(stat -c%s "$DUMP_FILE" 2>/dev/null || echo 0)
            if [ $size -gt 1000 ]; then
                echo "  ✅ 检测到新集开始（dump 已写 $size 字节）"
                kill -15 "$PHASE2_PID" 2>/dev/null
                sleep 2
                kill_profile_firefox
                break
            fi
        fi
    done

    if [ $NEXT_WAIT_COUNT -ge $NEXT_STALL ]; then
        echo "  ⏰ $NEXT_STALL 秒内无新内容，停止"
        kill -9 "$PHASE2_PID" 2>/dev/null
        kill_profile_firefox
        break
    fi

    EPISODE_INDEX=$((EPISODE_INDEX + 1))
done

# ─────────────────────────────────────────────────────────────
# 最终输出
# ─────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  最终结果"
echo "════════════════════════════════════════════════════════════"
echo ""
if [ ${#EPISODE_FILES[@]} -eq 0 ]; then
    echo "❌ 无 mp4 输出"
    echo "日志: $LOG"
    grep "StreamDumper" "$LOG" | head -5
    exit 1
fi

echo "  输出文件（${#EPISODE_FILES[@]} 集）："
for f in "${EPISODE_FILES[@]}"; do
    ls -lh "$f"
    ffprobe -v error -show_format -show_streams "$f" 2>&1 \
        | grep -E "codec_name|profile|width|height|duration=|nb_frames" | head -6 | sed 's/^/    /'
    echo ""
done

echo "💡 播放: ffplay '${EPISODE_FILES[0]}'"
