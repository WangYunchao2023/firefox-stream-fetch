#!/bin/bash
# firefox-stream-fetch capture.sh — v4.4.2 统一入口
#
# 用法:
#   capture.sh [URL] [OPTIONS]
#
# URL — 可选。不填则 Phase 1 开 about:newtab，用户在 Firefox 地址栏手动输入
# OPTIONS:
#   --output DIR              保存目录（默认：~/Videos/firefox抓取/）
#   --auto-next [N]           playlist 自动连集；带 N → 抓满 N 集（含起始集）自动终止，不带 N → 抓到最后一集
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
MAX_EPISODES=0        # 0 = 不限；>0 = 共抓满该集数后自动终止（功能自 v4.4.0 引入，由 --auto-next N 指定）
SKIP_PHASE1=0
KEEP_H264=1
ONLY_MP4=0
URL=""
PROFILE_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)          OUTPUT_DIR="$2"; shift 2;;
        --auto-next)
            AUTO_NEXT=1
            shift
            # v4.4.0: 可选集数上限 — --auto-next N → 共抓最多 N 集（含起始集），不带 N → 不限
            if [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ]; then
                MAX_EPISODES="$1"
                shift
            fi
            ;;
        --skip-phase1)     SKIP_PHASE1=1; shift;;
        --keep-h264)       KEEP_H264=1; shift;;
        --only-mp4)        ONLY_MP4=1; shift;;
        --profile)         PROFILE_PATH="$2"; shift 2;;
        --proxy)           FORCE_PROXY="$2"; shift 2;;
        --help|-h)
            cat <<HELP
firefox-stream-fetch 统一抓取脚本 v4.4.2

用法:
    capture.sh [URL] [OPTIONS]

URL:
    不填写 → Phase 1 开空白页，在 Firefox 地址栏手动输入
    填写   → 直接作为初始 URL

OPTIONS:
    --output DIR              mp4 保存目录（默认：~/Videos/firefox抓取/）
    --auto-next [N]           playlist 自动连集（每集独立 mp4：host-01.mp4, host-02.mp4...
                              ）；带 N → 共抓满 N 集（含起始集）后自动终止，不带 N → 抓到最后一集
    --skip-phase1             跳过 Phase 1（profile 已有可用 cookie 时等价行为）
    --keep-h264               保留 .h264/.aac 中间 dump（默认不删）
    --only-mp4                封装成功后删除全部中间文件，仅保留最终 .mp4（默认：全部保留）
    --profile PATH            自定义 profile 路径
    --proxy URL               强制指定代理（http://host:port 或 socks5://host:port）

例子:
    capture.sh
    capture.sh https://www.olevod.com/player/vod/1-82695-1.html
    capture.sh https://www.yfsp.tv/watch?v=ztgsSWh5mPZEhhazLjYUG6 --auto-next          # 抓到最后一集
    capture.sh https://www.yfsp.tv/watch?v=ztgsSWh5mPZEhhazLjYUG6 --auto-next 3        # 只抓前 3 集
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

    # 5. 清理上次残留的 .phase1_url（仅清理不同 profile 的，保留当前 profile 的）
    # Phase 1 → Phase 2 共用同一 PROFILE，.phase1_url 是 URL 交接的关键文件
    # 不能在这里删除，否则 Phase 2 找不到 URL
    # 仅在 Phase 1 完成后才清理：phase1() 内部 return 前会删除 lock 文件，.phase1_url 由 Phase 2 消费后自动残留（无影响）
    # 如需强制清理：显式传 --clear-phase1-url 参数
    if [ -n "${FORCE_CLEANUP_PHASE1_URL:-}" ] && [ -n "${PROFILE:-}" ] && [ -f "$PROFILE/.phase1_url" ]; then
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

# 遍历该 PID 下所有窗口，找第一个非 placeholder 的真实标题
# placeholder 列表：Firefox 未加载页面 / about:home / 等会误判的标题
get_firefox_real_title() {
    local pid="$1"
    local wids
    wids=$(XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" \
        xdotool search --pid "$pid" 2>/dev/null)
    [ -z "$wids" ] && return 1
    for wid in $wids; do
        local title
        title=$(XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" \
            xdotool getwindowname "$wid" 2>/dev/null)
        if [ -n "$title" ] && \
           [[ "$title" != "Nightly" && \
                "$title" != "Firefox" && \
                "$title" != "Mozilla Firefox" && \
                "$title" != "firefox-default" && \
                "$title" != "New Tab" && \
                "$title" != "about:home" && \
                "$title" != "about:newtab" ]]; then
            echo "$title"
            return 0
        fi
    done
    return 1
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

# 从 firefox sessionstore 文件解析用户实际访问的 URL
# 用于 phase1 firefox 关闭后,把用户实际访问的 URL 传给 phase2,免去手动重输
# 用法: _extract_phase1_url <profile_dir>
_extract_phase1_url() {
    local profile="$1"
    # 按优先级尝试多个 sessionstore 文件来源
    local -a candidates=(
        "$profile/sessionstore-backups/recovery.jsonlz4"
        "$profile/sessionstore-backups/recovery.baklz4"
        "$profile/sessionstore.js"
    )
    local session_file=""
    for candidate in "${candidates[@]}"; do
        if [ -f "$candidate" ]; then
            session_file="$candidate"
            break
        fi
    done
    [ -z "$session_file" ] && return 1

    local result=""
    # 对 LZ4 文件，添加重试逻辑（Firefox 退出后 sessionstore 可能需要时间落盘）
    local retries=0
    local max_retries=8
    while [ $retries -lt $max_retries ]; do
        result=$(python3 - "$session_file" 2>/dev/null << 'PYEOF'
import sys, json, lz4.block
session_file = sys.argv[1]
with open(session_file, 'rb') as f:
    raw = f.read()
if raw.startswith(b'mozLz40\x00'):
    data = lz4.block.decompress(raw[8:])
else:
    data = raw
d = json.loads(data)
# 按时间顺序收集所有 URL（可能有多个 tab/redirect）
urls = []
for w in d.get('windows', []):
    for t in w.get('tabs', []):
        for e in t.get('entries', []):
            u = e.get('url', '')
            if u.startswith('http://') or u.startswith('https://'):
                urls.append(u)
# 返回最后一个（最新的）URL
if urls:
    print(urls[-1])
PYEOF
)
        if [ -n "$result" ]; then
            echo "$result"
            return 0
        fi
        # LZ4 文件可能还在被 Firefox 写入,等待后重试
        if [[ "$session_file" == *.lz4* ]]; then
            sleep 1
            retries=$((retries + 1))
            continue
        fi
        break
    done

    # 所有候选文件都尝试完毕,返回空
    return 1
}

# 从 places.sqlite 拿用户访问过的 http(s) URL（最可靠）
# Firefox 每次访问 URL 都会同步写入 places.sqlite 的 moz_places 表
# 相比 sessionstore-backups/recovery.jsonlz4（异步写入，50% 只含 about:newtab）可靠得多
# 注意：sqlite3 需在 Firefox 完全退出后调用（避开文件锁）
# 用法: _extract_phase1_url_places <profile_dir>
#   退出码 0: 拿到 URL（输出 URL）
#   退出码 1: 未拿到（profile 不存在 / 无 places.sqlite / 无 http URL）
_extract_phase1_url_places() {
    local profile="$1"
    local places="$profile/places.sqlite"
    [ -f "$places" ] || return 1

    # 取最近访问的 http(s) URL（排除 about:/chrome:/file:// 等内部页）
    # last_visit_date 是微秒时间戳，ORDER BY DESC LIMIT 1 取最新
    # 过滤掉 CF challenge URL（含 __cf_chl），避免 phase2 重进 CF 挑战页
    local url
    url=$(sqlite3 "$places" \
        "SELECT url FROM moz_places
         WHERE last_visit_date IS NOT NULL
           AND (url LIKE 'http://%' OR url LIKE 'https://%')
           AND url NOT LIKE '%__cf_chl%'
         ORDER BY last_visit_date DESC LIMIT 1" 2>/dev/null)
    if [ -n "$url" ]; then
        echo "$url"
        return 0
    fi
    return 1
}

# 通过 BiDi 拿到 firefox 当前所有 tab 的 URL，找第一个 http(s) URL
# 【Phase 1 不再使用——开 BiDi 会让地址栏变红触发 CF 反复验证】
# 仅保留供未来参考（如 Phase 2 等场景）
# 用法: _query_phase1_url_bidi [firefox_pid]
#   退出码 0: 拿到 URL（输出 URL）
#   退出码 1: 未拿到
#   退出码 2: BiDi 不可达
_query_phase1_url_bidi() {
    local BIDI_PORT="${MONITOR_BIDI_PORT:-9222}"
    # 先探测端口是否可达
    (echo > "/dev/tcp/127.0.0.1/$BIDI_PORT") 2>/dev/null || return 2

    # 用 websocket-client 连 BiDi，调 browsingContext.getTree 拿所有 tab URL
    python3 - "$BIDI_PORT" << 'PYEOF' 2>/dev/null
import json, sys
try:
    import websocket
except ImportError:
    sys.exit(3)
port = sys.argv[1]
try:
    ws = websocket.create_connection(f"ws://127.0.0.1:{port}/session", timeout=3, suppress_origin=True)
except Exception:
    sys.exit(2)
try:
    msg_id = 1
    ws.send(json.dumps({
        "id": msg_id,
        "method": "browsingContext.getTree",
        "params": {"maxDepth": 3},
    }))
    while True:
        resp = ws.recv()
        try:
            r = json.loads(resp)
        except Exception:
            continue
        if r.get("id") != msg_id:
            continue
        if r.get("type") != "success":
            sys.exit(1)
        # 递归遍历 contexts 找第一个 http(s) URL
        contexts = r.get("result", {}).get("contexts", []) or []
        def walk(ctx):
            url = ctx.get("url", "") or ""
            if url.startswith(("http://", "https://")):
                return url
            for ch in ctx.get("children", []) or []:
                u = walk(ch)
                if u:
                    return u
            return None
        for ctx in contexts:
            u = walk(ctx)
            if u:
                print(u)
                sys.exit(0)
        sys.exit(1)
finally:
    try:
        ws.close()
    except Exception:
        pass
PYEOF
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
    echo "🚀 启动 Firefox（Phase 1: sandbox 默认 + 不开 BiDi 避免 CF 指纹）..."
    echo "   起始 URL: $start_url"

    # 【关键】Phase 1 不开 BiDi！开 BiDi 会让地址栏变红 → CF 检测到调试端口 → 反复弹验证
    # URL 获取走 places.sqlite（Firefox 同步写入历史数据库，最可靠）
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
        # 遍历该 PID 下所有窗口，找第一个非 placeholder 的真实标题
        title=$(get_firefox_real_title "$PID")
        if [ -n "$title" ]; then
            if echo "$title" | grep -qi "Just a moment"; then
                [ $saw_cf -eq 0 ] && echo "  [$elapsed s] ⏳ CF 挑战中..." && saw_cf=1
            else
                echo "  ✅ [$elapsed s] 检测到页面加载完成（标题: '$title'）"
                # 给页面再 5s 让 MediaSource 进入 first segment，places.sqlite 同步记录访问
                # 注意：不开 BiDi（地址栏变红触发 CF 反复挑战），URL 走 places.sqlite 获取
                sleep 5

                echo "  🔪 关闭 Phase 1 Firefox（SIGTERM 保存 session/cookie）..."
                kill -15 "$PID" 2>/dev/null || true
                # 等待 firefox 进程自然退出（sessionstore/cookies 同步需要时间）
                local ff_exit_wait=0
                while kill -0 "$PID" 2>/dev/null && [ $ff_exit_wait -lt 10 ]; do
                    sleep 1
                    ff_exit_wait=$((ff_exit_wait + 1))
                done
                if kill -0 "$PID" 2>/dev/null; then
                    echo "  ⚠️  Firefox 未响应 SIGTERM，强制退出"
                    kill -9 "$PID" 2>/dev/null || true
                    sleep 1
                fi
                echo "  ✅ Firefox 已退出 (${ff_exit_wait}s)"
                kill -9 "$PID" 2>/dev/null || true

                # 等待 sessionstore 写完整（Firefox 退出后 sessionstore 是异步写入的）
                # 先等文件出现 + 稳定，再读取
                local session_sync=0
                local max_session_sync=20
                while [ "$session_sync" -lt "$max_session_sync" ]; do
                    if [ -f "$PROFILE/sessionstore-backups/recovery.jsonlz4" ] && \
                       [ -f "$PROFILE/cookies.sqlite" ]; then
                        # 文件存在，再等 2s 确保写入完成
                        sleep 2
                        echo "  ✅ sessionstore + cookies 文件已就绪 (${session_sync}s)"
                        break
                    fi
                    sleep 1
                    session_sync=$((session_sync + 1))
                done
                [ "$session_sync" -ge "$max_session_sync" ] && \
                    echo "  ⚠️  sessionstore 文件等待超时 (${max_session_sync}s)"

                # 优先从 places.sqlite 拿 URL（Firefox 同步写入历史数据库，最可靠）
                # sessionstore 异步写入 50% 只含 about:newtab，places.sqlite 每次访问必写
                # sqlite3 需在 Firefox 完全退出后调用（避开文件锁）
                local phase1_url=""
                phase1_url=$(_extract_phase1_url_places "$PROFILE")
                if [ -n "$phase1_url" ]; then
                    echo "$phase1_url" > "$PROFILE/.phase1_url"
                    echo "  📎 Phase 1 实际 URL（places.sqlite）: $phase1_url（phase2 自动续接）"
                else
                    echo "  🔄 places.sqlite 未拿到 URL，尝试 sessionstore 兜底..."
                    # sessionstore 兜底：recovery.jsonlz4 → recovery.baklz4 → sessionstore.js
                    phase1_url=$(_extract_phase1_url "$PROFILE")
                    if [ -n "$phase1_url" ]; then
                        echo "$phase1_url" > "$PROFILE/.phase1_url"
                        echo "  📎 Phase 1 实际 URL（sessionstore）: $phase1_url（phase2 自动续接）"
                    else
                        # 兜底：检查 sessionstore.js（非 LZ4 格式，可能已写入）
                        if [ -f "$PROFILE/sessionstore.js" ]; then
                            phase1_url=$(python3 -c "
import sys, json
with open('$PROFILE/sessionstore.js', 'rb') as f:
    raw = f.read()
try:
    d = json.loads(raw) if not raw.startswith(b'mozLz40') else json.loads(lz4.block.decompress(raw[8:]))
except:
    d = {}
urls = [e.get('url','') for w in d.get('windows',[]) for t in w.get('tabs',[]) for e in t.get('entries',[])]
urls = [u for u in urls if u.startswith('http')]
if urls: print(urls[-1])
" 2>/dev/null)
                            if [ -n "$phase1_url" ]; then
                                echo "$phase1_url" > "$PROFILE/.phase1_url"
                                echo "  📎 Phase 1 实际 URL（sessionstore.js）: $phase1_url（phase2 自动续接）"
                            fi
                        fi
                        if [ -z "$phase1_url" ]; then
                            echo "  ⚠️  无法从 sessionstore 提取 URL，phase2 将用 about:home"
                        fi
                    fi
                fi

                # 检查 cookies 状态
                if [ -f "$PROFILE/cookies.sqlite" ] && [ -s "$PROFILE/cookies.sqlite" ]; then
                    local cf_count
                    cf_count=$(sqlite3 "$PROFILE/cookies.sqlite" \
                        "SELECT COUNT(*) FROM moz_cookies WHERE name='cf_clearance' AND expiry > strftime('%s','now')" \
                        2>/dev/null || echo 0)
                    if [ "$cf_count" -gt 0 ]; then
                        echo "  ✅ Cookie 已落盘 ($cf_count 条 cf_clearance)"
                    else
                        echo "  ⚠️  无 cf_clearance cookie（可能不需要 CF / 验证未完成）"
                    fi
                fi

                clear_locks
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

    # 【关键修复】Phase 1 写的 user.js 有 browser.startup.page=3 (恢复上次会话)，
    # 与 -no-session-restore 冲突，导致 Firefox 偶尔不加载命令行传入的 URL。
    # user.js 优先级 > prefs.js，所以只改 prefs.js 不够。
    # 这里直接 sed 删除 user.js 里冲突的 prefs，并写 Phase 2 用的覆盖值。
    local UJS="$PROFILE/user.js"
    if [ -f "$UJS" ]; then
        # 删除 Phase 1 的冲突 prefs
        sed -i '/user_pref("browser\.startup\.page"/d' "$UJS" 2>/dev/null || true
        sed -i '/user_pref("browser\.sessionstore\.resume_from_crash"/d' "$UJS" 2>/dev/null || true
        sed -i '/user_pref("browser\.sessionstore\.max_resumed_crashes"/d' "$UJS" 2>/dev/null || true
        # Phase 2 覆盖：startup.page=1 (home page) + resume_from_crash=false，这样 Firefox 会加载命令行传入的 URL
        cat >> "$UJS" << 'UJPJEOF'
// === Phase 2 覆盖：让 Firefox 加载命令行传入的 URL，不要恢复上次会话 ===
user_pref("browser.startup.page", 1);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.sessionstore.max_resumed_crashes", 0);
UJPJEOF
        echo "  🔧 Phase 2 重写 user.js 冲突 prefs (startup.page=1 + resume_from_crash=false)"
    fi

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

    # 确保 Phase 1 Firefox 完全退出 + cookies.sqlite 锁释放
    echo "   ⏳ 等待 Phase 1 Firefox 完全退出..."
    local wait_exit=0
    while [ $wait_exit -lt 10 ]; do
        # 检查 profile 中是否还有 firefox 进程
        local ff_running
        ff_running=$(ps -ef | grep -v grep | grep -F "firefox" | grep -F -- "-profile $PROFILE" | wc -l)
        if [ "$ff_running" -eq 0 ]; then
            # 等文件锁释放
            sleep 1
            echo "  ✅ Phase 1 Firefox 已完全退出"
            break
        fi
        sleep 1
        wait_exit=$((wait_exit + 1))
    done
    if [ $wait_exit -ge 10 ]; then
        echo "  ⚠️  Phase 1 Firefox 退出超时，强制清理"
        ps -ef | grep -v grep | grep -F "firefox" | grep -F -- "-profile $PROFILE" | awk '{print $2}' | xargs -r kill -9 2>/dev/null || true
    fi

    # 验证 cookies.sqlite 是否存在且可读取
    if [ -f "$PROFILE/cookies.sqlite" ]; then
        local cookie_size
        cookie_size=$(stat -c%s "$PROFILE/cookies.sqlite" 2>/dev/null || echo 0)
        echo "  📎 cookies.sqlite 大小: $cookie_size bytes"
        if [ "$cookie_size" -gt 0 ]; then
            local cf_check
            cf_check=$(sqlite3 "$PROFILE/cookies.sqlite" "SELECT COUNT(*) FROM moz_cookies WHERE name='cf_clearance'" 2>/dev/null || echo 0)
            echo "  📎 cf_clearance cookies: $cf_check"
        fi
    else
        echo "  ⚠️  警告：cookies.sqlite 不存在，Phase 2 可能无法复用 CF 验证"
    fi

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

    # .pts 文本文件默认保存到与 mp4 同一目录
    PTS_FILE="${OUTPUT_DIR}/pts_$(basename "${DUMP_FILE%.*}").pts"
    echo "📎 PTS dump: $PTS_FILE (MOZ_STREAM_DUMP_PTS_FILE)"
    export MOZ_STREAM_DUMP_PTS_FILE="$PTS_FILE"
    export MOZ_STREAM_DUMP_PATH="$DUMP_FILE"
    # 预热 firefox stdout/stderr 写到 $LOG（让 firefox 自己的错误信息能保留）
    export MOZ_LOG_FILE="$LOG"
    # 清理 Firefox 内部日志文件（.moz_log 由子进程生成，无害但会堆积磁盘）
    find "$OUTPUT_DIR" -maxdepth 1 -name '*.moz_log' -delete 2>/dev/null || true

    # Phase 2 URL 优先级：命令行 URL > phase1 URL（places.sqlite → sessionstore 兜底）> about:home
    # phase1 firefox 关闭后,查 places.sqlite 拿真实访问 URL（同步写入,最可靠）写到 $PROFILE/.phase1_url
    # places.sqlite 拿不到才 fallback 到 sessionstore（异步写入不可靠）
    # phase2 自动续接,免去用户手动重输
    local PHASE2_URL=""
    local MANUAL_URL_MODE=0
    
    # 调试：检查 .phase1_url 文件
    if [ -f "$PROFILE/.phase1_url" ]; then
        echo "  📎 调试：.phase1_url 文件存在，内容=$(cat "$PROFILE/.phase1_url" 2>/dev/null | head -1)"
    else
        echo "  ⚠️  调试：.phase1_url 文件不存在"
    fi
    
    if [ -n "${URL:-}" ]; then
        PHASE2_URL="$URL"
        echo "  📎 Phase2 URL 来自命令行: $PHASE2_URL"
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
        echo "   🔧 手工 URL 模式：URL 自动传入，等网站自动播放即可"
    fi
    echo ""

    # monitor_run 内部日志（_monitor_log 写 stderr）同时输出到终端 + 写 LOG,
    # 让用户能看 firefox 启动 / 预热 / 真 firefox 启动 / daemon ready 进度
    # 传递 MANUAL_URL_MODE 给 monitor_run，手工模式下无限等待 playing
    local monitor_result
    monitor_result=$(monitor_run "$FF" "$PROFILE" "$PHASE2_URL" \
        "$DUMP_FILE" "$AUDIO_DUMP" "$SIDECAR" "$MANUAL_URL_MODE" 2> >(tee -a "$LOG" >&2))

    # 过滤监控输出中的 BiDi JSON 泄漏（daemon 启动/停止时可能输出 {"ok": true, ...} 污染 reason）
    # 保留最后一行（格式为 reason|interrupt|video|audio）作为有效输出
    local clean_output
    clean_output=$(echo "$monitor_result" | grep -v '^{' | grep -v '^$' | tail -1)
    if [ -z "$clean_output" ]; then
        clean_output=$(echo "$monitor_result" | grep -E '^(ended|stall_limit|paused_too_long|max_interrupts|next_episode)' | tail -1)
    fi
    monitor_result="${clean_output:-$monitor_result}"
    echo "$monitor_result"
    local reason interrupt final_video final_audio
    IFS='|' read -r reason interrupt final_video final_audio <<< "$monitor_result"
    # 安全处理：确保 interrupt 为整数，空值默认为 0
    if ! [[ "$interrupt" =~ ^[0-9]+$ ]]; then
        interrupt=0
    fi

    DUMP_FILE="$final_video"
    AUDIO_DUMP="$final_audio"

    # trim 视频 dump：按 .pts.final.pts 段边界去掉 warmup/trail 帧
    if [ -n "${PTS_FILE:-}" ] && [ -s "$PTS_FILE" ]; then
        echo ""
        echo "🔧 二次处理视频 .pts (pts_finalize.py) ..."
        python3 "${SCRIPT_DIR}/pts_finalize.py" "$PTS_FILE" 2>&1 | sed 's/^/  /' || true
        # 注：audio .pts 不走 pts_finalize — AAC 无 B 帧重排，dump 顺序就是 PTS
        # 顺序，trim_segments.py 直接读 raw .pts 检测 >5s PTS 跳变选主段即可。
    fi
    if [ -n "${PTS_FILE:-}" ] && [ -s "${PTS_FILE}.final.pts" ] && [ -s "$DUMP_FILE" ]; then
        echo ""
        echo "🔧 备份 .h264 → .h264.original ..."
        cp -p "$DUMP_FILE" "${DUMP_FILE}.original" \
            && echo "  [video] ✅ $(stat -c%s "${DUMP_FILE}.original") bytes" \
            || echo "  ⚠️ 备份失败（trim 将报错退出）" >&2

        # audio 备份（v4.3.1+）：trim_segments.py 会按 video main 段的 PTS 范围
        # 同步裁 audio，保持 A/V 时间轴对齐。备份缺失或 cp 失败 → trim 自动跳过。
        if [ -s "$AUDIO_DUMP" ]; then
            echo "🔧 备份 .aac → .aac.original ..."
            cp -p "$AUDIO_DUMP" "${AUDIO_DUMP}.original" \
                && echo "  [audio] ✅ $(stat -c%s "${AUDIO_DUMP}.original") bytes" \
                || echo "  ⚠️ audio 备份失败（trim_segments.py 将跳过 audio 裁剪）" >&2
        else
            echo "⏭️  无 .aac dump（纯视频或音频缺失），跳过 audio 备份"
        fi

        echo ""
        echo "🔧 trim 视频帧，去掉 warmup/trail (trim_segments.py) ..."
        # trim_segments.py 会从 .original 读帧，写到 .h264（用临时文件 + 原子 rename）
        # 必须传完整 basename（$out_base 去目录），不是 $BASE_NAME（profile 时间戳）
        python3 "${SCRIPT_DIR}/trim_segments.py" "$(basename "$out_base")" "$OUTPUT_DIR" 2>&1 | sed 's/^/  /' || true
    else
        if [ -n "${PTS_FILE:-}" ] && [ ! -s "${PTS_FILE:-}" ]; then
            echo "  ⚠️  跳过 trim: PTS 文件为空或缺失"
        elif [ ! -s "$DUMP_FILE" ]; then
            echo "  ⚠️  跳过 trim: DUMP_FILE 无内容"
        fi
    fi

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
    # v4.3.7: PyAV 解释器钉死（可用 MUX_PY 覆盖）。PTS 保真封装要求 'av' 可导入；
    # 缺失时显著告警，避免静默降级成 fps-guess 兜底导致音画错位。
    local mux_py="${MUX_PY:-python3}"
    if ! "$mux_py" -c "import av" >/dev/null 2>&1; then
        echo "  ⚠️  [$mux_py] 无法 import 'av'(PyAV) → PTS 封装将回退 ffmpeg fps-guess（音画可能错位）"
        echo "      修复: export MUX_PY=<装有 PyAV 的 python>"
    fi
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

    # 预先计算音频时长（audio as clock）：用 AAC 帧数 × 1024 / sample_rate
    # 视频 PTS 不可信时（firefox mTime chunk 边界跳变），用音频时长作为视频时间轴基准
    local audio_duration_us=0
    # v4.3.9: audio extraction uses a standalone prefix -- old logic shared <base>.raw/.pts with video:
    # while the video version still existed the re-extract was skipped -> wc -l counted VIDEO frames as AAC frames -> wrong clock source
    local a_base="${audio%.aac}__aud"
    local extracted_a_raw="${a_base}.raw"
    local extracted_a_pts="${a_base}.pts"
    if [ -s "$audio" ]; then
        python3 "$extractor" "$audio" 0 "$a_base" >/dev/null 2>&1 || true
    fi
    if [ -s "$extracted_a_pts" ]; then
        local a_n_frames a_sample_rate
        a_n_frames=$(wc -l < "$extracted_a_pts")
        a_sample_rate=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$audio" 2>/dev/null | head -1)
        [ -z "$a_sample_rate" ] && a_sample_rate="44100"
        audio_duration_us=$((a_n_frames * 1024 * 1000000 / a_sample_rate))
        echo "  🎵 audio as clock: ${a_n_frames} 帧 × 1024 / ${a_sample_rate}Hz = ${audio_duration_us}us ($((audio_duration_us/1000000)).$(( (audio_duration_us/100000) % 10 ))s)"
    fi

    # 用 PyAV 封装（保留原始 PTS）
    if [ -s "$extracted_pts" ] && [ -s "$extracted_raw" ]; then
        local first_pts last_pts n_frames dur_s
        first_pts=$(head -1 "$extracted_pts")
        last_pts=$(tail -1 "$extracted_pts")
        n_frames=$(wc -l < "$extracted_pts")
        dur_s=$(awk -v a="$first_pts" -v b="$last_pts" 'BEGIN{printf "%.3f", (b-a)/1000000}')
        echo "  ✅ PTS: $n_frames 帧，时长 ${dur_s}s, 首帧 PTS=${first_pts}us"

        # 检查 PTS 是否可信：span 过短（firefox MSE mTime 在 chunk 边界会乱）
        # 判定: span < n_frames / 30 秒 -> PTS 不可信，优先用音频时长作时钟源
        local pts_reliable=1
        local fps_detected=""
        if [ "$n_frames" -gt 100 ]; then
            local min_dur
            min_dur=$(awk -v n="$n_frames" 'BEGIN{printf "%.3f", n/30}')
            local dur_check
            dur_check=$(awk -v d="$dur_s" 'BEGIN{print (d < '"$min_dur"') ? "1" : "0"}')
            if [ "$dur_check" = "1" ]; then
                pts_reliable=0
                if [ "$audio_duration_us" -gt 0 ]; then
                    fps_detected=$(awk -v n="$n_frames" -v d="$audio_duration_us" 'BEGIN{printf "%.4f", n*1000000/d}')
                    echo "  ⚠️  PTS span 过短（${dur_s}s < ${min_dur}s），从音频时长推算视频帧率 ${fps_detected}fps（audio as clock）"
                else
                    # 无音频参考时，fallback 到 SPS 读帧率
                    fps_detected=$(ffprobe -v error -select_streams v:0 \
                        -of default=noprint_wrappers=1:nokey=1 \
                        -show_entries stream=r_frame_rate "$extracted_raw" 2>/dev/null \
                        | awk -F'/' 'NF==2 && $2>0 {printf "%.4f", $1/$2; exit} NF==1 {printf "%.4f", $1; exit}')
                    [ -z "$fps_detected" ] || [ "$fps_detected" = "0.0000" ] && fps_detected="25"
                    echo "  ⚠️  PTS span 过短（${dur_s}s < ${min_dur}s），从 SPS 读帧率 ${fps_detected}fps"
                fi
            fi
        fi

        # PyAV 封装：每帧写入实际 PTS，保留与 dump 一致的时间轴
        if "$mux_py" "$muxer_py" "$base" video --audio-duration-us "$audio_duration_us" 2>&1 | tee /tmp/mux_py.log; then
            local py_v="${base}.mp4"
            if [ -s "$py_v" ]; then
                # v4.3.9: $base.mp4 与最终输出 $out 同路径，合并会自读自写（ffmpeg: Output same as Input）→ 移到独立临时文件
                mv -f "$py_v" "${out}.tmpv_py.mp4"
                tmp_v_py="${out}.tmpv_py.mp4"
                echo "  ✅ PyAV mux 成功（保留原始 PTS）"
            else
                echo "  ⚠️  PyAV 输出为空，回退到 ffmpeg fps"
                local fps
                if [ "$pts_reliable" = "0" ]; then
                    fps="$fps_detected"
                else
                    fps=$(awk -v n="$n_frames" -v d="$dur_s" 'BEGIN{printf "%.4f", n/d}')
                fi
                ffmpeg -y -fflags +genpts -r "$fps" -i "$extracted_raw" \
                    -c:v copy -movflags +faststart "$tmp_v" -loglevel error
                # v4.3.5+: 修 video 首包负 PTS。-fflags +genpts 会让首包 PTS=负 1~2 帧 (-83ms for 24fps)
                local v_neg_ts=$(ffprobe -v error -of csv=p=0 -show_entries packet=pts_time -select_streams v:0 -read_intervals %+#1 "$tmp_v" 2>/dev/null | head -1)
                if [ -n "$v_neg_ts" ] && awk -v t="$v_neg_ts" 'BEGIN{exit !(t<0)}'; then
                    local v_off=$(awk -v t="$v_neg_ts" 'BEGIN{printf "%.6f", -t}')
                    ffmpeg -y -i "$tmp_v" -output_ts_offset "$v_off" -c:v copy \
                        -movflags +faststart "${tmp_v%.mp4}_fixed.mp4" -loglevel error
                    mv "${tmp_v%.mp4}_fixed.mp4" "$tmp_v"
                    echo "  [v4.3.5+] 修正 video 首包 PTS (原 ${v_neg_ts}s → 0)"
                fi
                tmp_v_py="$tmp_v"
            fi
        else
            echo "  ⚠️  PyAV mux 失败，回退到 ffmpeg fps"
            local fps
            if [ "$pts_reliable" = "0" ]; then
                fps="$fps_detected"
            else
                fps=$(awk -v n="$n_frames" -v d="$dur_s" 'BEGIN{printf "%.4f", n/d}')
            fi
            ffmpeg -y -fflags +genpts -r "$fps" -i "$extracted_raw" \
                -c:v copy -movflags +faststart "$tmp_v" -loglevel error
            local v_neg_ts=$(ffprobe -v error -of csv=p=0 -show_entries packet=pts_time -select_streams v:0 -read_intervals %+#1 "$tmp_v" 2>/dev/null | head -1)
            if [ -n "$v_neg_ts" ] && awk -v t="$v_neg_ts" 'BEGIN{exit !(t<0)}'; then
                local v_off=$(awk -v t="$v_neg_ts" 'BEGIN{printf "%.6f", -t}')
                ffmpeg -y -i "$tmp_v" -output_ts_offset "$v_off" -c:v copy \
                    -movflags +faststart "${tmp_v%.mp4}_fixed.mp4" -loglevel error
                mv "${tmp_v%.mp4}_fixed.mp4" "$tmp_v"
                echo "  [v4.3.5+] 修正 video 首包 PTS (原 ${v_neg_ts}s → 0)"
            fi
            tmp_v_py="$tmp_v"
        fi
    fi

    # v4.3.9: 视频封装完成 → 立即删掉视频的 raw/pts（与音频提取共用同名文件），
    # 强制下面 audio-as-clock 预解析重新生成 AUDIO 数据（此前 wc -l 数到的是视频帧数 → 时钟源错误）；
    # 首帧 PTS 提前保存供 sync_off 计算
    local video_first_pts_us=""
    [ -s "$extracted_pts" ] && video_first_pts_us=$(head -1 "$extracted_pts")
    rm -f "$extracted_raw" "$extracted_pts"

    if [ ! -f "$tmp_v_py" ]; then
        echo "  ⚠️  无视频 dump，跳过封装"
        rm -f "$extracted_raw" "$extracted_pts" "$extracted_a_raw" "$extracted_a_pts" "$tmp_a_py"
        return 1
    fi

    # 合并音频 —— 用 PyAV 封装音频（保留 PTS），再用 ffmpeg -c copy 合并（保留双方 PTS）
    if [ -s "$audio" ]; then
        local tmp_a_py="${audio%.aac}.m4a"
        # v4.3.6+: -itsoffset 仅在非空时追加（空值会让 ffmpeg 报错 → 回退链一路失败 → 音轨静默丢失）；
        # fallback 输入优先用已提取的 ADTS（SDFA 原始 dump ffmpeg 无法直接 demux）。默认指向 $audio（旧 ADTS 流）。
        local TS_ARGS=()
        local A_IN="$audio"

        if [ -s "$extracted_a_raw" ] && [ -s "$extracted_a_pts" ]; then
            # v4.3.5+: 计算 A/V PTS 偏移。如果 dump 里 video/audio 首帧 PTS 有偏移 (>50ms)，
            # 合同时加 -itsoffset 让 audio 后面偏移量开始，两轨同 mp4 时刻同一流时间 → 同步。
            # v4.3.9: 视频首帧 PTS 用提前保存的值（旧代码 video/audio 读同一个文件 → 偏移恒为 0）
            local sync_off=""
            local a_fp
            a_fp=$(head -1 "$extracted_a_pts" 2>/dev/null)
            if [ -n "$video_first_pts_us" ] && [ -n "$a_fp" ]; then
                sync_off=$(awk -v v="$video_first_pts_us" -v a="$a_fp" 'BEGIN{printf "%.6f", (a-v)/1e6}')
                if [ -n "$sync_off" ] && awk -v s="$sync_off" 'BEGIN{exit !(s+0 > 0.05)}'; then
                    echo "  [v4.3.5+] A/V offset = ${sync_off}s (audio 晚于此)，加 -itsoffset"
                else
                    sync_off=""
                fi
            fi
            # v4.3.6+: extractor 成功 → ffmpeg 侧输入改用已提取 ADTS；sync_off 定稿后构造 itsoffset 参数
            [ -s "$extracted_a_raw" ] && A_IN="$extracted_a_raw"
            [ -n "$sync_off" ] && TS_ARGS=(-itsoffset "$sync_off")
            # PyAV 封装音频（保留 PTS）
            if "$mux_py" "$muxer_py" "$a_base" audio 2>&1 | tee -a /tmp/mux_py.log; then
                # v4.3.9: PyAV outputs <a_base>.m4a -> move to tmp_a_py path for downstream merge
                [ -f "${a_base}.m4a" ] && mv -f "${a_base}.m4a" "$tmp_a_py"
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
                            ffmpeg -y -i "$tmp_v_py" "${TS_ARGS[@]}" -i "$tmp_a_py" -c copy "$out" -loglevel error || {
                                mv "$tmp_v_py" "$out"; rm -f "$extracted_raw" "$extracted_pts" "$extracted_a_raw" "$extracted_a_pts" "$tmp_a_py"; return 1; }
                        }
                    rm -f "$tmp_v_py" "$tmp_a_py"
                else
                    echo "  ⚠️  PyAV 音频输出为空，回退"
                    ffmpeg -y -i "$tmp_v_py" "${TS_ARGS[@]}" -i "$A_IN" -c copy -map 0:v:0 -map 1:a:0 -movflags +faststart "$out" -loglevel error || { mv "$tmp_v_py" "$out"; rm -f "$extracted_raw" "$extracted_pts" "$extracted_a_raw" "$extracted_a_pts" "$tmp_a_py"; return 1; }
                fi
            else
                echo "  ⚠️  PyAV 音频 mux 失败，回退"
                local ar ch
                ar=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$audio" 2>/dev/null | head -1)
                ch=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$audio" 2>/dev/null | head -1)
                [ -z "$ar" ] && ar="44100"
                [ -z "$ch" ] && ch="2"
                ffmpeg -y -ar "$ar" -ac "$ch" -i "$A_IN" -c:a copy "$tmp_a_py" -loglevel error || {
                    ffmpeg -y -i "$tmp_v_py" "${TS_ARGS[@]}" -i "$A_IN" -c copy -map 0:v:0 -map 1:a:0 -movflags +faststart "$out" -loglevel error || { mv "$tmp_v_py" "$out"; rm -f "$extracted_raw" "$extracted_pts" "$extracted_a_raw" "$extracted_a_pts" "$tmp_a_py"; return 1; }
                } && ffmpeg -y -i "$tmp_v_py" "${TS_ARGS[@]}" -i "$tmp_a_py" -c copy -map 0:v:0 -map 1:a:0 -movflags +faststart "$out" -loglevel error || { mv "$tmp_v_py" "$out"; rm -f "$extracted_raw" "$extracted_pts" "$extracted_a_raw" "$extracted_a_pts" "$tmp_a_py"; return 1; }
            fi
        else
            # fallback: 旧 ADTS 流
            local ar ch
            ar=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$audio" 2>/dev/null | head -1)
            ch=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$audio" 2>/dev/null | head -1)
            [ -z "$ar" ] && ar="44100"
            [ -z "$ch" ] && ch="2"
            ffmpeg -y -ar "$ar" -ac "$ch" -i "$A_IN" -c:a copy "$tmp_a_py" -loglevel error || {
                ffmpeg -y -i "$tmp_v_py" "${TS_ARGS[@]}" -i "$A_IN" -c copy -map 0:v:0 -map 1:a:0 -movflags +faststart "$out" -loglevel error || { mv "$tmp_v_py" "$out"; rm -f "$extracted_raw" "$extracted_pts" "$extracted_a_raw" "$extracted_a_pts" "$tmp_a_py"; return 1; }
            } && ffmpeg -y -i "$tmp_v_py" "${TS_ARGS[@]}" -i "$tmp_a_py" -c copy -map 0:v:0 -map 1:a:0 -movflags +faststart "$out" -loglevel error || { mv "$tmp_v_py" "$out"; rm -f "$extracted_raw" "$extracted_pts" "$extracted_a_raw" "$extracted_a_pts" "$tmp_a_py"; return 1; }
        fi
        rm -f "$extracted_a_raw" "$extracted_a_pts"
    else
        mv "$tmp_v_py" "$out"
    fi

    rm -f "$extracted_raw" "$extracted_pts" "$extracted_a_raw" "$extracted_a_pts"

    # 统一清理临时 mp4/m4a（多分支中部分路径漏了 rm .tmpv.mp4/.m4a，留在 OUTPUT_DIR 变垃圾）
    rm -f "$tmp_v_py" "$tmp_a_py"

    echo "  ✅ mp4: $out"
    ls -lh "$out"
    ffprobe -v error -show_entries format=duration:stream=codec_name,width,height \
        -of default=nw=1 "$out" 2>/dev/null | sed 's/^/    /' | head -8
}



# ═══════════════════════════════════════════════════════════════════════
# 主循环
# ═════════════════════════════════════════════════

main() {
    local auto_next_desc="❌"
    if [ "$AUTO_NEXT" -eq 1 ]; then
        if [ "$MAX_EPISODES" -gt 0 ]; then
            auto_next_desc="✅ (≤${MAX_EPISODES} 集)"
        else
            auto_next_desc="✅ (抓到最后一集)"
        fi
    fi
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  firefox-stream-fetch v4.4.2                              ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo "  URL:           ${URL:-（空白页，手动输入）}"
    echo "  Profile:       $PROFILE"
    echo "  Output:        $OUTPUT_DIR"
    echo "  Auto-next:     $auto_next_desc"
    echo "  Only-mp4:      $([ $ONLY_MP4 -eq 1 ] && echo '✅ 删中间文件' || echo '❌ 保留中间文件(默认)')" 
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
                    # v4.4.0: 集数上限 — 本集已计入 $episode；达到 MAX_EPISODES 则不再切下一集，落到 break 走正常清理
                    if [ "$MAX_EPISODES" -gt 0 ] && [ "$episode" -ge "$MAX_EPISODES" ]; then
                        echo "🛑 已达到指定集数上限（--auto-next ${MAX_EPISODES}）：共抓 $episode 集，自动终止"
                    else
                        echo ""
                        echo "═══════════════════════════════════════════════════════"
                        echo "  ⏭️  自动切下一集 (--auto-next): $next_url"
                        echo "═══════════════════════════════════════════════════════"
                        URL="$next_url"
                        episode=$((episode + 1))
                        export EPISODE=$episode
                        continue
                    fi
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

    # 抓取完成后二次处理：pts_finalize + trim 已在 phase2 里每集 mux 之前跑过
    # 这里不再重复

    # 清理（除非 --keep-h264）
    if [ $KEEP_H264 -eq 0 ]; then
        echo ""
        echo "🧹 清理中间文件..."
        find "$OUTPUT_DIR" -name "${BASE_NAME}-*" \
            ! -name "*.mp4" ! -name "*.log" ! -name "*.sidecar.json" \
            ! -name "*.h264" ! -name "*.h264.original" \
            ! -name "*.aac" ! -name "*.aac.original" \
            -delete 2>/dev/null || true
        echo "  ✅ (保留 mp4 + log + sidecar + .h264 + .h264.original + .aac + .aac.original)"
    fi

    # --only-mp4: 仅保留最终 mp4，删除本次运行全部中间产物（dump/.original/pts/sidecar/log 等）
    if [ $ONLY_MP4 -eq 1 ]; then
        echo ""
        echo "🧹 --only-mp4: 删除中间文件..."
        find "$OUTPUT_DIR" -maxdepth 1 \( -name "${BASE_NAME}*" -o -name "pts_${BASE_NAME}*" \) \
            ! -name "*.mp4" -delete 2>/dev/null || true
        echo "  ✅ 仅保留 *.mp4"
    fi

    # 清理 Firefox 内部调试日志（.moz_log 由子进程生成）
    find "$OUTPUT_DIR" -maxdepth 1 -name '*.moz_log' -delete 2>/dev/null || true
    # 清理 bidi daemon 日志
    rm -f /tmp/bidi-daemon.log 2>/dev/null || true
    # 解除环境残留，避免影响后续进程
    unset MOZ_LOG_FILE 2>/dev/null || true

    echo ""
    echo "🏁 任务结束。"
    echo "📂 输出目录: $OUTPUT_DIR"
    ls -lh "$OUTPUT_DIR"/${BASE_NAME}*.mp4 2>/dev/null | head -5
}

main "$@"