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
        --proxy)           FORCE_PROXY="$2"; shift 2;;
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
    --proxy URL               强制指定代理（http://host:port 或 socks5://host:port）

例子:
    capture.sh
    capture.sh https://www.olevod.com/player/vod/1-82695-1.html
    capture.sh https://www.yfsp.tv/watch?v=ztgsSWh5mPZEhhazLjYUG6 --auto-next
    capture.sh https://www.youtube.com/watch?v=_n4SRDYkhqs --keep-h264
    capture.sh https://example.com/video --proxy socks5://127.0.0.1:1080

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
[ -z "$FF" ] && FF=$(find -L "$PROJECT/firefox/obj-x86_64-pc-linux-gnu" -path "*dist/bin/firefox" -type f -executable 2>/dev/null | head -1)
[ -z "$FF" ] && { echo "❌ 找不到 patched firefox（$PROJECT/obj-stream/*/dist/bin/firefox 或 $PROJECT/firefox/obj-x86_64-pc-linux-gnu/dist/bin/firefox）"; exit 1; }
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
    # --proxy 强制覆盖：写到标准 *proxy 变量,让 firefox 自然继承
    if [ -n "${FORCE_PROXY:-}" ]; then
        if [[ "$FORCE_PROXY" == socks5://* ]]; then
            export socks_proxy="$FORCE_PROXY" SOCKS_PROXY="$FORCE_PROXY"
        else
            export http_proxy="$FORCE_PROXY" https_proxy="$FORCE_PROXY" all_proxy="$FORCE_PROXY"
            export HTTP_PROXY="$FORCE_PROXY" HTTPS_PROXY="$FORCE_PROXY" ALL_PROXY="$FORCE_PROXY"
        fi
    fi
    # 其他情况：环境变量自然继承（firefox 自动读系统代理，见使用说明.md）
}

has_proxy_env() {
    [ -n "${FORCE_PROXY:-}${http_proxy:-}${https_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}${all_proxy:-}${ALL_PROXY:-}${socks_proxy:-}${SOCKS_PROXY:-}" ]
}

# ═══════════════════════════════════════════════════════════════════════
# 公共：wid / 标题 / 拉前台
# ═══════════════════════════════════════════════════════════════════════
clear_locks() {
    rm -f "$PROFILE/.parentlock" "$PROFILE/parent.lock" "$PROFILE/lock"
}

# 启动前清理：杀掉上次残留 firefox / bidi daemon 进程，清 profile lock / socket / phase1_url 临时文件
# 解决上次崩溃或手动 ctrl+c 退出后,残留进程持有 lock 导致本次 firefox 启动失败 / BiDi 端口冲突
_cleanup_on_start() {
    # 临时关闭 set -e：pipeline 里 grep 无匹配会 exit 1，但这是正常情况不应该让脚本退出
    set +e
    local cleaned=0

    # 1. 残留 firefox 进程（同一 profile 路径）
    if [ -n "${PROFILE:-}" ] && [ -d "$PROFILE" ]; then
        local ff_pids
        ff_pids=$(ps -ef | grep -v grep | grep -F "firefox" | grep -F -- "-profile $PROFILE" | awk '{print $2}' 2>/dev/null)
        if [ -n "$ff_pids" ]; then
            echo "🧹 清理残留 firefox 进程（profile=$PROFILE_NAME）: $(echo "$ff_pids" | wc -l) 个"
            echo "$ff_pids" | xargs -r kill -9 2>/dev/null || true
            sleep 1
            cleaned=1
        fi
    fi

    # 2. 残留 bidi daemon 进程（任何 profile 都可能残留）
    local daemon_pids
    daemon_pids=$(ps -ef | grep -v grep | grep -F "bidi-state.py daemon" | awk '{print $2}' 2>/dev/null)
    if [ -n "$daemon_pids" ]; then
        echo "🧹 清理残留 bidi daemon 进程: $(echo "$daemon_pids" | wc -l) 个"
        echo "$daemon_pids" | xargs -r kill -9 2>/dev/null || true
        cleaned=1
    fi

    # 3. 残留 unix socket（bidi daemon 的）
    if [ -S /tmp/bidi-monitor.sock ]; then
        rm -f /tmp/bidi-monitor.sock
        echo "🧹 清理残留 unix socket: /tmp/bidi-monitor.sock"
        cleaned=1
    fi

    # 4. profile lock 文件（防止 firefox 启动拒绝）
    if [ -n "${PROFILE:-}" ]; then
        rm -f "$PROFILE/.parentlock" "$PROFILE/parent.lock" "$PROFILE/lock" 2>/dev/null || true
    fi

    # 5. 上次 phase1 提取的 URL 临时文件（避免本次误用上次的 URL）
    if [ -n "${PROFILE:-}" ] && [ -f "$PROFILE/.phase1_url" ]; then
        rm -f "$PROFILE/.phase1_url"
        echo "🧹 清理上次的 phase1 URL 临时文件"
        cleaned=1
    fi

    [ $cleaned -eq 1 ] && sleep 1  # 给系统一点时间释放端口 / inode
    set -e
    return 0
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

# 从 firefox sessionstore-backups/recovery.jsonlz4 (mozLz40 格式) 解析最近 tab 的 URL
# 用于 phase1 firefox 关闭后,把用户实际访问的 URL 传给 phase2,免去手动重输
# 用法: _extract_phase1_url <profile_dir>
_extract_phase1_url() {
    local profile="$1"
    local session_file=""
    # 优先 recovery.jsonlz4 (最新),否则 fallback 到 sessionstore.js (老格式)
    if [ -f "$profile/sessionstore-backups/recovery.jsonlz4" ]; then
        session_file="$profile/sessionstore-backups/recovery.jsonlz4"
    elif [ -f "$profile/sessionstore.js" ]; then
        session_file="$profile/sessionstore.js"
    else
        return 1
    fi
    python3 -c "
import sys, json
try:
    try:
        import lz4.block
        with open('$session_file', 'rb') as f:
            raw = f.read()
        if raw.startswith(b'mozLz40\x00'):
            data = lz4.block.decompress(raw[8:])
        else:
            data = raw
    except ImportError:
        with open('$session_file', 'rb') as f:
            raw = f.read()
        data = raw[8:] if raw.startswith(b'mozLz40\x00') else raw
    d = json.loads(data)
    for w in d.get('windows', []):
        for t in w.get('tabs', []):
            for e in t.get('entries', []):
                url = e.get('url', '')
                if url.startswith('http://') or url.startswith('https://'):
                    print(url)
                    sys.exit(0)
except Exception:
    sys.exit(1)
" 2>/dev/null
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

    # 准备新 profile：删旧 profile 重建（避免残留 lock / 损坏 sessionstore 导致 firefox crash）
    rm -rf "$PROFILE"
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
                # 给页面再 5s 让 MediaSource 进入 first segment，sessionstore 同步记录最后访问的 URL
                # 之前 sleeps 2s + 5s = 7s, 但 SIGTERM 后 xpcshell shutdown 异步同步 sessionstore.jsonlz4
                # 偶尔 5s 不够，导致 _extract_phase1_url 拿不到 URL。
                # 这里在 SIGTERM 之后再多等等到 sessionstore 出现 yfsp 类 URL 再继续。
                sleep 5
                echo "  🔪 关闭 Phase 1 Firefox（SIGTERM 保存 session/cookie）..."
                kill -15 "$PID" 2>/dev/null || true
                # 等待 sessionstore.jsonlz4 / .baklz4 出现最后的真 URL（包含 http(s)://）
                # 最准同时机：firefox 退出会依次写 recovery.jsonlz4 包含未来恢复需要的最近访问的 URL
                local session_wait=0
                while [ "$session_wait" -lt 15 ]; do
                    if [ -f "$PROFILE/sessionstore-backups/recovery.jsonlz4" ]; then
                        local probe
                        probe=$(python3 -c "
import sys, json
try:
    import lz4.block
    with open('$PROFILE/sessionstore-backups/recovery.jsonlz4', 'rb') as f:
        raw = f.read()
    data = lz4.block.decompress(raw[8:]) if raw.startswith(b'mozLz40\x00') else raw
    d = json.loads(data)
    for w in d.get('windows', []):
        for t in w.get('tabs', []):
            for e in t.get('entries', []):
                u = e.get('url', '')
                if u.startswith('http'):
                    print(u); sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
" 2>/dev/null)
                        if [ -n "$probe" ]; then
                            echo "  📎 phase1 退出前 会话检测到 http URL=$probe"
                            break
                        fi
                    fi
                    sleep 1
                    session_wait=$((session_wait + 1))
                done
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
                            # 提取 phase1 firefox 实际 URL（从 sessionstore 解析），让 phase2 自动用这个 URL
                            local phase1_url=""
                            phase1_url=$(_extract_phase1_url "$PROFILE")
                            if [ -n "$phase1_url" ]; then
                                echo "$phase1_url" > "$PROFILE/.phase1_url"
                                echo "  📎 Phase 1 实际 URL: $phase1_url（phase2 自动续接）"
                            fi
                            return 0
                        fi
                    fi
                    sleep 1
                    wait_cookie=$((wait_cookie + 1))
                done

                # 没 cf_clearance 也继续（可能不需要 CF）
                clear_locks

                # 提取 phase1 firefox 实际 URL（从 sessionstore 解析），让 phase2 自动用这个 URL
                local phase1_url=""
                phase1_url=$(_extract_phase1_url "$PROFILE")
                if [ -n "$phase1_url" ]; then
                    echo "$phase1_url" > "$PROFILE/.phase1_url"
                    echo "  📎 Phase 1 实际 URL: $phase1_url（phase2 自动续接）"
                else
                    echo "  ⚠️  无法从 sessionstore 提取 URL，phase2 将用 about:home"
                fi

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

    # --skip-phase1 时 profile 目录可能不存在,确保存在
    [ -d "$PROFILE" ] || mkdir -p "$PROFILE"

    # 关 sandbox（StreamDumper 写 /tmp 需要）
    # prefs.js 可能不存在（全新 profile）, touch 一下
    local PJS="$PROFILE/prefs.js"
    [ -f "$PJS" ] || touch "$PJS"
    sed -i '/user_pref("security\.sandbox/d' "$PJS" 2>/dev/null || true
    cat >> "$PJS" << 'EP'
// === Phase 2: 关 sandbox 让 StreamDumper 写盘 ===
user_pref("security.sandbox.content.level", 0);
user_pref("security.sandbox.gmp.level", 0);
user_pref("security.sandbox.rdd.level", 0);
user_pref("security.sandbox.socket.level", 0);
user_pref("security.sandbox.utility.level", 0);
// Phase 2 不恢复 session，避免重新打开 Phase 1 的 tabs
user_pref("browser.startup.page", 0);
user_pref("browser.sessionstore.resume_from_crash", false);
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

    # Phase 2 必须 export MOZ_STREAM_DUMP_PATH 给 StreamDumper（Phase 1 设为 /dev/null）
    export MOZ_STREAM_DUMP_PATH="$DUMP_FILE"
    # 预热 firefox stdout/stderr 写到 $LOG（让 firefox 自己的错误信息能保留）
    export MOZ_LOG_FILE="$LOG"

    # Phase 2 URL 优先级：命令行 URL > phase1 URL（从 sessionstore 提取）> about:home
    # phase1 firefox 关闭后,我们解析 sessionstore 拿到用户实际访问的 URL,写到 $PROFILE/.phase1_url
    # phase2 自动续接,免去用户手动重输
    local PHASE2_URL=""
    local MANUAL_URL_MODE=0
    if [ -n "${URL:-}" ]; then
        PHASE2_URL="$URL"
    elif [ -s "$PROFILE/.phase1_url" ]; then
        PHASE2_URL=$(cat "$PROFILE/.phase1_url" 2>/dev/null || true)
        if [ -n "$PHASE2_URL" ]; then
            echo "  📎 Phase2 URL 续接 Phase1: $PHASE2_URL"
            MANUAL_URL_MODE=1
        fi
    fi
    PHASE2_URL="${PHASE2_URL:-about:home}"

    # 明确告知用户 firefox 要启动（避免他们以为 phase2 卡住）
    echo "🚀 启动 Phase 2 Firefox..."
    echo "   URL: $PHASE2_URL"
    echo "   Profile: $PROFILE"
    echo "   详细日志: $LOG"
    if [ $MANUAL_URL_MODE -eq 1 ]; then
        echo "   🔧 手工 URL 模式：等待用户点击播放后再开始抓取"
    fi
    echo ""

    # monitor_run 内部日志（_monitor_log 写 stderr）同时输出到终端 + 写 LOG,
    # 让用户能看 firefox 启动 / 预热 / 真 firefox 启动 / daemon ready 进度
    # 传递 MANUAL_URL_MODE 给 monitor_run，手工模式下无限等待 playing
    local monitor_result
    monitor_result=$(monitor_run "$FF" "$PROFILE" "$PHASE2_URL" \
        "$DUMP_FILE" "$AUDIO_DUMP" "$SIDECAR" "$MANUAL_URL_MODE" 2> >(tee -a "$LOG" >&2))

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
        next_episode)
            echo "  ⏭️  检测到下一集（当前集 dump 已滚动到 .p1，合成 mp4）"
            ;;
        *)                 echo "  ⚠️  reason=$reason";;
    esac
    if [ "$interrupt" -gt 0 ]; then
        echo "  🔄 期间中断 $interrupt 次后恢复"
    fi

    # 合成 mp4
    # 注：next_episode 时 DUMP_FILE 已被 monitor 滚到 .p1.h264，需传 out_base 给 mux 让其正确算 parts glob
    if [ -s "$DUMP_FILE" ] || [ -s "$AUDIO_DUMP" ]; then
        mux_to_mp4 "$DUMP_FILE" "$AUDIO_DUMP" "${out_base}.mp4" "$out_base"
    else
        echo "  ⚠️  Phase 2 无 dump 文件（视频可能未进入播放）"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# mp4 封装（含分段 concat + AAC 双轨 + H.264 清洗）
# ═══════════════════════════════════════════════════════════════════════
mux_to_mp4() {
    local dump="$1" audio="$2" out="$3" base_arg="${4:-}"
    # base 默认 = dump 去 .h264（next_episode 时 dump 已是 .p1.h264，需要 OUT_BASE 真实 base 来算 parts）
    local base="${base_arg:-${dump%.h264}}"

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
        # 先清洗 H.264 流：去除开头的垃圾帧（非 IDR、时间戳异常等）
        # 使用 ffmpeg 的 h264_mp4toannexb + 重新封装来修复时间戳和 SPS/PPS
        local cleaned_h264="${base}.cleaned.h264"
        echo "  🧹 清洗 H.264 流（去除开头异常帧）..."
        # 先转为 mp4 容器（ffmpeg 会自动处理 SPS/PPS 和时间戳），再导出为干净的 annex-b
        ffmpeg -y -fflags +genpts+igndts -i "$dump" -c:v copy -f h264 "$cleaned_h264" -loglevel error 2>/dev/null || {
            echo "  ⚠️  H.264 清洗失败，回退到直接封装"
            cp "$dump" "$cleaned_h264"
        }

        # 帧率检测：raw H.264 无可靠时间戳，ffprobe 探测常错。
        # 优先用 sidecar.duration（视频元素实际时长）算 fps。
        # fallback: ffprobe (raw h264 → 25/1)
        local fps="25/1" frame_count=0 sidecar_dur=""
        if [ -f "${base_arg}.sidecar.json" ] || [ -f "${dump%.h264}.sidecar.json" ]; then
            local sc="${base_arg}.sidecar.json"
            [ ! -f "$sc" ] && sc="${dump%.h264}.sidecar.json"
            sidecar_dur=$(jq -r '.duration // empty' "$sc" 2>/dev/null)
        fi
        if [ -n "$sidecar_dur" ] && [ "$sidecar_dur" != "null" ] && [ "$sidecar_dur" != "0" ]; then
            frame_count=$(ffprobe -v error -count_packets -select_streams v:0 -show_entries stream=nb_read_packets -of csv=p=0 "$cleaned_h264" 2>/dev/null)
            if [ -n "$frame_count" ] && [ "$frame_count" -gt 0 ]; then
                fps=$(awk -v f="$frame_count" -v d="$sidecar_dur" 'BEGIN{printf "%.4f", f/d}')
                echo "  🎯 帧率修正: $frame_count 帧 / ${sidecar_dur}s = ${fps} fps (sidecar)"
            fi
        else
            local probed
            probed=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of csv=p=0 "$cleaned_h264" 2>/dev/null | head -1)
            [ -n "$probed" ] && fps="$probed"
            echo "  ⚠️  无 sidecar.duration，ffprobe 探测 fps=$fps (可能不准)"
        fi
        ffmpeg -y -fflags +genpts -r "$fps" -i "$cleaned_h264" -c:v copy -movflags +faststart "$tmp_v" -loglevel error || {
            rm -f "$cleaned_h264"; return 1; }
        rm -f "$cleaned_h264"
    fi

    if [ ! -f "$tmp_v" ]; then
        echo "  ⚠️  无视频 dump，跳过封装"
        return 1
    fi

    # 合并音频 —— 自动探测采样率/声道
    if [ -s "$audio" ]; then
        local tmp_a="${out}.tmpa.m4a"
        local ar ch
        ar=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$audio" 2>/dev/null | head -1)
        ch=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$audio" 2>/dev/null | head -1)
        [ -z "$ar" ] && ar="44100"
        [ -z "$ch" ] && ch="2"
        ffmpeg -y -i "$audio" -c:a copy "$tmp_a" -loglevel error || {
            echo "  ⚠️  音频预处理失败，尝试直接合并"; ffmpeg -y -i "$tmp_v" -i "$audio" -c copy -map 0:v:0 -map 1:a:0 -movflags +faststart "$out" -loglevel error || { mv "$tmp_v" "$out"; return 1; }
        } && ffmpeg -y -i "$tmp_v" -i "$tmp_a" -c copy -map 0:v:0 -map 1:a:0 -movflags +faststart "$out" -loglevel error || {
            echo "  ⚠️  音频合并失败，留视频轨"; mv "$tmp_v" "$out"; return 1; }
        rm -f "$tmp_v" "$tmp_a"
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

    # 启动前清理：避免上次崩溃 / 手动退出留下的残留导致本次启动失败
    _cleanup_on_start

    local phase2_ret=0
    local episode=1
    export EPISODE=$episode
    while true; do
        if [ $SKIP_PHASE1 -eq 0 ]; then
            phase1 || { echo "❌ Phase 1 失败"; return 1; }
        fi
        phase2 || phase2_ret=$?
        
        # --- 下一集检测（无论 AUTO_NEXT 是否开启，都查 sidecar.next_url） ---
        #   AUTO_NEXT=1 → 自动切下一集（每 phase2 = 1 集，每集独立 mp4）
        #   AUTO_NEXT=0 → 默认行为，提示后结束（当前集已保存）
        local sidecar
        sidecar=$(ls -t "$OUTPUT_DIR"/${BASE_NAME}-*.sidecar.json 2>/dev/null | head -1)
        if [ -n "$sidecar" ] && [ -f "$sidecar" ]; then
            local next_url
            next_url=$(jq -r '.next_url // empty' "$sidecar" 2>/dev/null)
            if [ -n "$next_url" ] && [ "$next_url" != "null" ]; then
                if [ $AUTO_NEXT -eq 1 ]; then
                    echo ""
                    echo "═══════════════════════════════════════════════════════"
                    echo "  ⏭️  自动切下一集 (--auto-next): $next_url"
                    echo "═══════════════════════════════════════════════════════"
                    URL="$next_url"
                    episode=$((episode + 1))
                    export EPISODE=$episode
                    continue
                else
                    echo ""
                    echo "ℹ️  检测到下一集但未开启 --auto-next，当前集已保存为 mp4："
                    echo "    下一集 URL: $next_url"
                    echo "    如需自动抓完整个 playlist，请加 --auto-next 重启。"
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