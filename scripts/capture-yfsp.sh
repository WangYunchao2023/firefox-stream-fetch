#!/bin/bash
# yfsp.tv 视频抓取脚本 — 两阶段法
#
# 问题：我们的 patched Firefox 在 CF 验证后 WebGL content process 会崩，
#       但同时关 sandbox 又会被 CF 拒绝发 cookie。
#       
# 方案：两阶段
#   Phase 1: sandbox 开启 → 你手动过 CF → Firefox 崩 → cookie 落盘
#   Phase 2: sandbox 关闭 → 重启 → cookie 有效 → StreamDumper 写 dump
#
set -e

PROJECT="/home/wangyc/Documents/软件类工作/firefox-stream-fetch"
PROFILE="/tmp/firefox-yfsp-dump-profile"          # 新的 profile（不与旧冲突）
DUMP_DIR="/tmp/moz_stream_dumps"
FF=$(find -L "$PROJECT/obj-stream" -path "*dist/bin/firefox" -type f -executable 2>/dev/null | head -1)
FF_DIR=$(dirname "$FF")
DUMP_FILE="$DUMP_DIR/yfsp-$(date +%Y%m%d-%H%M%S).h264"
LOG="$DUMP_DIR/yfsp.log"
mkdir -p "$DUMP_DIR"
> "$LOG"

# ============================================================
# Phase 1 — 拿 CF cookie（sandbox 正常）
# ============================================================
phase1() {
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║    Phase 1 — 获取 CF cookie（sandbox 正常）         ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""

    # 清理旧的 profile（确保全新）
    rm -rf "$PROFILE"
    mkdir -p "$PROFILE"

    # user.js：只写必要的，**不关 sandbox，不改 UA**
    cat > "$PROFILE/user.js" << 'PJ'
user_pref("network.proxy.type", 5);                   // 走 GNOME 系统代理（Aurora SOCKS5）
user_pref("media.autoplay.default", 0);
user_pref("browser.sessionstore.resume_from_crash", false);  // 崩了不弹恢复对话框
user_pref("browser.sessionstore.max_resumed_crashes", 0);    // 不自动恢复崩溃 session
user_pref("browser.startup.page", 3);                        // 恢复上次的标签页
user_pref("dom.webdriver.enabled", false);
user_pref("privacy.resistFingerprinting", false);
PJ

    export DISPLAY=:1
    export XAUTHORITY=/run/user/1000/gdm/Xauthority
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY MOZ_STREAM_DUMP_PATH

    echo "📦 新 profile: $PROFILE"
    echo "🚀 启动 Firefox（sandbox 开启）..."
    echo ""

    setsid nohup "$FF" \
        -profile "$PROFILE" \
        -no-remote --new-instance \
        "https://www.yfsp.tv/play/zImbBGABDR2" \
        < /dev/null > "$LOG" 2>&1 &
    FF_PID=$!
    disown

    # 拉窗口到前台
    for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1.5
        WID=$(XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
            xdotool search "Just a moment" 2>/dev/null | head -1)
        [ -z "$WID" ] && WID=$(XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
            xdotool search --classname "firefox-default" 2>/dev/null | head -1)
        if [ -n "$WID" ]; then
            echo "🪟 找到窗口 WID=$WID"
            XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
                xdotool windowsize "$WID" 1280 800 &>/dev/null
            XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
                xdotool windowmove "$WID" 200 100 &>/dev/null
            XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
                xdotool windowactivate "$WID" windowraise "$WID" &>/dev/null
            break
        fi
    done

    echo ""
    echo "┌────────────────────────────────────────────────────┐"
    echo "│  👆  请在 Firefox 窗口中手动通过 CF 人机验证       │"
    echo "│                                                   │"
    echo "│  通过后 Firefox 很可能会崩溃重启 / 自动恢复，     │"
    echo "│  脚本会自动检测并进入 Phase 2。                    │"
    echo "│                                                   │"
    echo "│  ⏳ 正在等待 Firefox 进程结束..."                   │
    echo "└────────────────────────────────────────────────────┘"
    echo ""

    # 轮询等 Firefox 主进程退出
    while kill -0 "$FF_PID" 2>/dev/null; do
        sleep 5
    done
    echo "  ✅ Firefox 进程已结束"
}

# ============================================================
# Phase 1.5 — 检测 cookie + 杀自动恢复的 Firefox
# ============================================================
check_cookie() {
    echo ""
    echo "  🔍 检测 cf_clearance cookie..."

    # 清可能残留的锁
    rm -f "$PROFILE/.parentlock" "$PROFILE/parent.lock" "$PROFILE/lock"

    # 如果有 cookies.sqlite，读它
    if [ -f "$PROFILE/cookies.sqlite" ]; then
        CF_COUNT=$(sqlite3 "$PROFILE/cookies.sqlite" \
            "SELECT COUNT(*) FROM moz_cookies WHERE name='cf_clearance'" 2>/dev/null || echo "0")
        if [ "$CF_COUNT" -gt 0 ]; then
            echo "  ✅ cf_clearance 已存在（$CF_COUNT 个）"
            return 0
        fi
    fi
    echo "  ❌ 未检测到 cf_clearance cookie"
    return 1
}

kill_auto_restored_firefox() {
    # Firefox 崩后可能自动重启（session restore），杀掉
    for PID in $(ps -ef | grep -v grep | grep "yfsp-dump-profile" | awk '{print $2}'); do
        kill -9 "$PID" 2>/dev/null && echo "  🔪 杀掉自动恢复的 Firefox PID=$PID"
    done
    sleep 2
    rm -f "$PROFILE/.parentlock" "$PROFILE/parent.lock" "$PROFILE/lock"
}

# ============================================================
# Phase 2 — StreamDumper 抓取（sandbox 关闭）
# ============================================================
phase2() {
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║    Phase 2 — StreamDumper 抓取（sandbox 关闭）     ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""

    # 注：直接修改 profile 的 prefs.js，追加 sandbox 关闭配置
    # 这只在 Phase 2 才执行，不影响 Phase 1 的 CF 验证
    PJS="$PROFILE/prefs.js"
    if [ -f "$PJS" ]; then
        # 删掉之前可能残留的错误配置
        sed -i '/user_pref("security\.sandbox/d' "$PJS" 2>/dev/null || true
    fi
    cat >> "$PJS" <<'EP'
// === Phase 2: 关 sandbox 让 StreamDumper 写 /tmp/ ===
user_pref("security.sandbox.content.level", 0);
user_pref("security.sandbox.gmp.level", 0);
user_pref("security.sandbox.rdd.level", 0);
user_pref("security.sandbox.socket.level", 0);
user_pref("security.sandbox.utility.level", 0);
EP

    export MOZ_STREAM_DUMP_PATH="$DUMP_FILE"
    export DISPLAY=:1
    export XAUTHORITY=/run/user/1000/gdm/Xauthority

    echo "📦 Dump: $DUMP_FILE"
    echo "🚀 重启 Firefox（sandbox 关闭，StreamDumper 就绪）..."
    echo ""

    setsid nohup "$FF" \
        -profile "$PROFILE" \
        -no-remote --new-instance \
        "https://www.yfsp.tv/play/zImbBGABDR2" \
        < /dev/null > "$LOG" 2>&1 &
    FF_PID=$!
    disown

    # 拉窗口
    for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1.5
        WID=$(XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
            xdotool search --classname "firefox-default" 2>/dev/null | head -1)
        if [ -n "$WID" ]; then
            echo "🪟 找到窗口 WID=$WID"
            XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
                xdotool windowsize "$WID" 1280 800 &>/dev/null
            XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
                xdotool windowmove "$WID" 400 150 &>/dev/null
            XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
                xdotool windowactivate "$WID" windowraise "$WID" &>/dev/null
            break
        fi
    done

    # 监控 dump 进度
    echo ""
    echo "  ⏳ 正在等待 StreamDumper 触发..."
    LAST_SIZE=0
    STALL_COUNT=0

    while true; do
        sleep 10

        if kill -0 "$FF_PID" 2>/dev/null; then
            : # Firefox 还活着
        else
            echo ""
            echo "  ⚠️  Firefox 已退出（可能又崩了？）"
            peek_dump
            return 1
        fi

        if [ -f "$DUMP_FILE" ]; then
            SIZE=$(stat -c%s "$DUMP_FILE" 2>/dev/null || echo 0)
            if [ "$SIZE" -gt "$LAST_SIZE" ]; then
                DELTA=$((SIZE - LAST_SIZE))
                echo "  ✅ Dump: $(numfmt --to=iec $SIZE)  (+$(numfmt --to=iec $DELTA))"
                LAST_SIZE=$SIZE
                STALL_COUNT=0
            else
                STALL_COUNT=$((STALL_COUNT + 1))
                echo "  ⏳ 文件 ${STALL_COUNT}次检测无增长（视频可能播完）"
                if [ "$STALL_COUNT" -ge 12 ]; then
                    echo "  📦 120s 无增长，停止监控"
                    break
                fi
            fi
        else
            echo "  ⏳ 暂无 dump（等待视频加载 + StreamDumper 触发）"
        fi
    done
    return 0
}

# ============================================================
# 善后 — 检查 dump 文件
# ============================================================
peek_dump() {
    echo ""
    echo "========================================"
    echo "  最终结果"
    echo "========================================"
    if [ -f "$DUMP_FILE" ]; then
        echo "  📁 Dump: $(ls -lh "$DUMP_FILE" | awk '{print $5}')"
        echo "  路径: $DUMP_FILE"
        FPS=$(ffprobe -v error -count_frames -select_streams v:0 \
            -show_entries stream=nb_read_frames -of csv=p=0 "$DUMP_FILE" 2>/dev/null || echo 'N/A')
        echo "  帧数: $FPS"
        echo ""
        echo "  💡 播放: ffplay -f h264 -i '$DUMP_FILE'"
        echo "  转 mp4: ffmpeg -framerate 25 -i '$DUMP_FILE' -c copy output.mp4"
    else
        echo "  ❌ 无 dump 文件"
        echo "  日志: $LOG"
        grep "StreamDumper\|dump" "$LOG" | head -5
    fi
}

# ============================================================
# 主流程
# ============================================================
phase1
kill_auto_restored_firefox

if check_cookie; then
    phase2
    peek_dump
else
    echo ""
    echo "❌ 未检测到 cf_clearance cookie。"
    echo "  可能原因："
    echo "  - CF 验证未通过"
    echo "  - Firefox 非正常退出（崩溃时 cookie 未落盘）"
    echo ""
    echo "  重新运行脚本即可再试一次。"
    exit 1
fi
