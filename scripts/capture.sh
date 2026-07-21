#!/bin/bash
# firefox-stream-fetch capture.sh — v3.2 统一入口
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
firefox-stream-fetch 统一抓取脚本 v3.2

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
# 用法: _extract_phase1_url <profile_dir> [max_retries]
# 从 sessionstore 提取 phase1 firefox 最后访问的 http(s) URL。
# 返回 0 + 输出 URL 成功，非 0 表示失败。
# 增强: firefox SIGTERM 后可能重写 sessionstore，轮询多次确保拿到稳定状态。
_extract_phase1_url() {
    local profile="$1"
    local max_retries="${2:-5}"
    local retry=0
    local session_files=()

    while [ $retry -lt $max_retries ]; do
        # 多候选文件（按优先级）
        session_files=()
        [ -f "$profile/sessionstore-backups/recovery.jsonlz4" ] && \
            session_files+=("$profile/sessionstore-backups/recovery.jsonlz4")
        [ -f "$profile/sessionstore-backups/recovery.baklz4" ] && \
            session_files+=("$profile/sessionstore-backups/recovery.baklz4")
        [ -f "$profile/sessionstore-backups/previous.jsonlz4" ] && \
            session_files+=("$profile/sessionstore-backups/previous.jsonlz4")
        [ -f "$profile/sessionstore.js" ] && \
            session_files+=("$profile/sessionstore.js")

        if [ ${#session_files[@]} -eq 0 ]; then
            retry=$((retry + 1))
            sleep 1
            continue
        fi

        # 尝试每个候选文件
        for sf in "${session_files[@]}"; do
            local url
            url=$(python3 -c "
import sys, json
try:
    try:
        import lz4.block
        with open('$sf', 'rb') as f:
            raw = f.read()
        if raw.startswith(b'mozLz40\x00'):
            data = lz4.block.decompress(raw[8:])
        else:
            data = raw
    except ImportError:
        with open('$sf', 'rb') as f:
            raw = f.read()
        data = raw[8:] if raw.startswith(b'mozLz40\x00') else raw
    d = json.loads(data)
    # 优先: 最后一个 tab 的最后一个 entry
    last_url = None
    for w in d.get('windows', []):
        for t in w.get('tabs', []):
            for e in t.get('entries', []):
                u = e.get('url', '')
                if u.startswith('http://') or u.startswith('https://'):
                    last_url = u
    if last_url:
        print(last_url); sys.exit(0)
    sys.exit(2)
except Exception:
    sys.exit(1)
" 2>/dev/null)
            local rc=$?
            if [ $rc -eq 0 ] && [ -n "$url" ]; then
                echo "$url"
                return 0
            fi
        done

        retry=$((retry + 1))
        sleep 1
    done
    return 1
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
// === v3.2 Phase 1 反指纹 prefs（实测通过 CF Turnstile） ===
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
                            # firefox SIGTERM 后可能重写 sessionstore，多试几次
                            local phase1_url=""
                            phase1_url=$(_extract_phase1_url "$PROFILE" 10)
                            if [ -n "$phase1_url" ]; then
                                echo "$phase1_url" > "$PROFILE/.phase1_url"
                                echo "  📎 Phase 1 实际 URL: $phase1_url（phase2 自动续接）"
                            else
                                echo "  ⚠️  Sessionstore 10 次重试都拿不到 URL，phase2 将用 about:home + session restore"
                            fi
                            return 0
                        fi
                    fi
                    sleep 1
                    wait_cookie=$((wait_cookie + 1))
                done

                # 没 cf_clearance 也继续（可能不需要 CF）
                clear_locks
                # firefox SIGTERM 后可能重写 sessionstore，多试几次
                local phase1_url=""
                phase1_url=$(_extract_phase1_url "$PROFILE" 10)
                if [ -n "$phase1_url" ]; then
                    echo "$phase1_url" > "$PROFILE/.phase1_url"
                    echo "  📎 Phase 1 实际 URL: $phase1_url（phase2 自动续接）"
                else
                    echo "  ⚠️  无法从 sessionstore 提取 URL，phase2 将用 about:home + session restore"
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
// Phase 2 恢复 session (firefox 恢复 phase1 的标签页, cf_clearance cookie 复用, 不重新弹 CF)
user_pref("browser.startup.page", 3);
user_pref("browser.sessionstore.resume_from_crash", true);
EP

    clear_locks
    _apply_proxy_env

    local out_base=$(OUT_BASE)
    local DUMP_FILE="${out_base}.h264"
    local AUDIO_DUMP="${out_base}.aac"
    local SIDECAR="${out_base}.sidecar.json"

    echo "📦 预定 dump (sentinel 启用后才创建): $DUMP_FILE"
    echo "📦 预定 dump (sentinel 启用后才创建): $AUDIO_DUMP"
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
    echo "   ⏳ firefox 启动后，StreamDumper 默认丢弃所有 sample"
    echo "   ⏳ BiDi 监控 video.readyState>=3 + currentTime>1 后创建哨兵"
    echo "   ⏳ StreamDumper 检测到哨兵才开始写真视频帧 (才创建 dump 文件)"
    echo "   ⏳ 请在 firefox 中过 CF / 进入视频页面，不要 Ctrl+C 中断"
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
    local base="${base_arg:-${dump%.h264}}"

    echo "🎬 封装 → $out"

    local parts
    parts=$(ls "${base}".p*.h264 2>/dev/null | sort)

    local tmp_v="${out}.tmpv.mp4"
    local extractor="${SCRIPT_DIR}/sdfv_extract.py"
    local muxer_py="${SCRIPT_DIR}/mux_with_pts.py"
    local extracted_raw="${base}.raw"
    local extracted_pts="${base}.pts"
    local tmp_v_py="${out}.tmpv_py.mp4"  # PyAV 输出（保留原始 PTS）

    # 统一处理：解析 dump → .raw + .pts → 用 PyAV mux 成 mp4（保留 PTS）
    # 这样无论单段/多段，mp4 内每帧 PTS 与 dump 一致。
    if [ -n "$parts" ]; then
        # 多段：依次解析每段，累加 PTS 偏移，拼接 raw + pts
        echo "  (多段合并：$(echo "$parts" | wc -l) 段，按 PTS 拼接)"
        : > "$extracted_raw"
        : > "$extracted_pts"
        local pts_offset=0
        local last_pts=0
        for p in $parts; do
            echo "    📦 解析段：$p (pts_offset=${pts_offset}us)"
            if python3 "$extractor" "$p" "$pts_offset" 2>&1 | tee /tmp/sdfv_seg.log; then
                local seg_raw="${p%.h264}.raw"
                local seg_pts="${p%.h264}.pts"
                if [ -s "$seg_raw" ] && [ -s "$seg_pts" ]; then
                    cat "$seg_raw" >> "$extracted_raw"
                    cat "$seg_pts" >> "$extracted_pts"
                    last_pts=$(tail -1 "$seg_pts")
                    # 留 100ms 间隙避免 PTS 重叠
                    pts_offset=$((last_pts + 100000))
                else
                    echo "    ⚠️  段解析失败：$p"
                fi
                rm -f "$seg_raw" "$seg_pts"
            else
                echo "    ⚠️  段解析器运行失败：$p"
            fi
        done
    elif [ -s "$dump" ]; then
        # SDFV 格式：文件头 magic + SPS/PPS + 每帧 [size(4)][pts(8)][data]
        echo "  📦 解析 SDFV dump + 提取每帧 PTS..."
        if ! python3 "$extractor" "$dump" 2>&1 | tee /tmp/sdfv_extract.log; then
            echo "  ⚠️  解析器运行失败，回退到 ffprobe 探测"
            local fps
            fps=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of csv=p=0 "$dump" 2>/dev/null | head -1)
            [ -z "$fps" ] && fps="25/1"
            ffmpeg -y -fflags +genpts -r "$fps" -i "$dump" -c:v copy -movflags +faststart "$tmp_v" -loglevel error
            rm -f "$extracted_raw" "$extracted_pts"
            # 直接跳到音频合并
            tmp_v_py="$tmp_v"  # 没有 PyAV 版本，用 ffmpeg 输出
        fi
    fi

    # 用 PyAV 封装（保留原始 PTS）
    if [ -s "$extracted_pts" ] && [ -s "$extracted_raw" ]; then
        local first_pts last_pts n_frames dur_s
        first_pts=$(head -1 "$extracted_pts")
        last_pts=$(tail -1 "$extracted_pts")
        n_frames=$(wc -l < "$extracted_pts")
        dur_s=$(awk -v a="$first_pts" -v b="$last_pts" 'BEGIN{printf "%.3f", (b-a)/1000000}')
        echo "  ✅ PTS: $n_frames 帧，时长 ${dur_s}s, 首帧 PTS=${first_pts}us"

        # PyAV 封装：每帧写入实际 PTS，保留与 dump 一致的时间轴
        if python3 "$muxer_py" "$base" video 2>&1 | tee /tmp/mux_py.log; then
            local py_v="${base}.mp4"
            if [ -s "$py_v" ]; then
                tmp_v_py="$py_v"
                echo "  ✅ PyAV mux 成功（保留原始 PTS）"
            else
                echo "  ⚠️  PyAV 输出为空，回退到 ffmpeg fps"
                local fps
                fps=$(awk -v n="$n_frames" -v d="$dur_s" 'BEGIN{printf "%.4f", n/d}')
                ffmpeg -y -fflags +genpts -r "$fps" -i "$extracted_raw" \
                    -c:v copy -movflags +faststart "$tmp_v" -loglevel error
                tmp_v_py="$tmp_v"
            fi
        else
            echo "  ⚠️  PyAV mux 失败，回退到 ffmpeg fps"
            local fps
            fps=$(awk -v n="$n_frames" -v d="$dur_s" 'BEGIN{printf "%.4f", n/d}')
            ffmpeg -y -fflags +genpts -r "$fps" -i "$extracted_raw" \
                -c:v copy -movflags +faststart "$tmp_v" -loglevel error
            tmp_v_py="$tmp_v"
        fi
    fi

    rm -f "$extracted_raw" "$extracted_pts"

    if [ ! -f "$tmp_v_py" ]; then
        echo "  ⚠️  无视频 dump，跳过封装"
        return 1
    fi

    # 合并音频 —— 用 PyAV 封装音频（保留 PTS），再用 ffmpeg -c copy 合并（保留双方 PTS）
    if [ -s "$audio" ]; then
        local extracted_a_raw="${audio%.aac}.raw"
        local extracted_a_pts="${audio%.aac}.pts"
        local tmp_a_py="${audio%.aac}.m4a"

        if python3 "$extractor" "$audio" >/dev/null 2>&1 && [ -s "$extracted_a_raw" ] && [ -s "$extracted_a_pts" ]; then
            # PyAV 封装音频（保留 PTS）
            if python3 "$muxer_py" "${audio%.aac}" audio 2>&1 | tee -a /tmp/mux_py.log; then
                if [ -s "$tmp_a_py" ]; then
                    echo "  ✅ PyAV 音频 mux 成功"
                    # ffmpeg 合并两个 mp4，保留双方 PTS 时间轴
                    local ar ch
                    ar=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$tmp_a_py" 2>/dev/null | head -1)
                    ch=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$tmp_a_py" 2>/dev/null | head -1)
                    [ -z "$ar" ] && ar="44100"
                    [ -z "$ch" ] && ch="2"
                    ffmpeg -y -i "$tmp_v_py" -i "$tmp_a_py" \
                        -c copy -map 0:v:0 -map 1:a:0 \
                        -movflags +faststart "$out" -loglevel error || {
                            echo "  ⚠️  PTS 合并失败，尝试默认合并"
                            ffmpeg -y -i "$tmp_v_py" -i "$tmp_a_py" -c copy "$out" -loglevel error || {
                                mv "$tmp_v_py" "$out"; return 1; }
                        }
                    rm -f "$tmp_v_py" "$tmp_a_py"
                else
                    echo "  ⚠️  PyAV 音频输出为空，回退"
                    ffmpeg -y -i "$tmp_v_py" -i "$audio" -c copy -map 0:v:0 -map 1:a:0 -movflags +faststart "$out" -loglevel error || { mv "$tmp_v_py" "$out"; return 1; }
                fi
            else
                echo "  ⚠️  PyAV 音频 mux 失败，回退"
                local ar ch
                ar=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$audio" 2>/dev/null | head -1)
                ch=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$audio" 2>/dev/null | head -1)
                [ -z "$ar" ] && ar="44100"
                [ -z "$ch" ] && ch="2"
                ffmpeg -y -ar "$ar" -ac "$ch" -i "$audio" -c:a copy "$tmp_a_py" -loglevel error || {
                    ffmpeg -y -i "$tmp_v_py" -i "$audio" -c copy -map 0:v:0 -map 1:a:0 -movflags +faststart "$out" -loglevel error || { mv "$tmp_v_py" "$out"; return 1; }
                } && ffmpeg -y -i "$tmp_v_py" -i "$tmp_a_py" -c copy -map 0:v:0 -map 1:a:0 -movflags +faststart "$out" -loglevel error || { mv "$tmp_v_py" "$out"; return 1; }
            fi
        else
            # fallback: 旧 ADTS 流
            local ar ch
            ar=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$audio" 2>/dev/null | head -1)
            ch=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$audio" 2>/dev/null | head -1)
            [ -z "$ar" ] && ar="44100"
            [ -z "$ch" ] && ch="2"
            ffmpeg -y -ar "$ar" -ac "$ch" -i "$audio" -c:a copy "$tmp_a_py" -loglevel error || {
                ffmpeg -y -i "$tmp_v_py" -i "$audio" -c copy -map 0:v:0 -map 1:a:0 -movflags +faststart "$out" -loglevel error || { mv "$tmp_v_py" "$out"; return 1; }
            } && ffmpeg -y -i "$tmp_v_py" -i "$tmp_a_py" -c copy -map 0:v:0 -map 1:a:0 -movflags +faststart "$out" -loglevel error || { mv "$tmp_v_py" "$out"; return 1; }
        fi
        rm -f "$extracted_a_raw" "$extracted_a_pts"
    else
        mv "$tmp_v_py" "$out"
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
    echo "║  firefox-stream-fetch v3.2                                ║"
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