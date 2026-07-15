#!/bin/bash
# yfsp.tv 视频抓取脚本 — 两阶段法（2026-07-14 固化版）
#
# ═══════════════════════════════════════════════════════════════════════
# 关键发现 / 为什么这样设计
# ═══════════════════════════════════════════════════════════════════════
# CF Turnstile 检测 prefs 里两个特征就拒绝发 cf_clearance cookie：
#   1) general.useragent.override = "Chrome ..."  → Chrome UA 跑 Firefox，bot 信号
#   2) security.sandbox.*.level = 0  → 全沙箱关闭，bot 信号
#
# 解决：
#   Phase 1: sandbox 开启 + 用 Firefox 真实 UA → 用户手动过 CF → cookie 落盘
#   Phase 2: 同一 profile + sandbox 关闭（StreamDumper 写文件需要）
#            + 复制 cookie（cookie 复用）→ 视频播放 → dump
#
# 实测：上面这套 + 一次性手动过 CF 后，cookie 复用可持续几小时。
# ═══════════════════════════════════════════════════════════════════════
set -e

PROJECT="/home/wangyc/Documents/软件类工作/firefox-stream-fetch"
PROFILE="/tmp/firefox-yfsp-dump-profile"          # profile 复用（保留 cookie）
DUMP_DIR="/tmp/moz_stream_dumps"
FF=$(find -L "$PROJECT/obj-stream" -path "*dist/bin/firefox" -type f -executable 2>/dev/null | head -1)
[ -z "$FF" ] && { echo "❌ 找不到 firefox"; exit 1; }

mkdir -p "$DUMP_DIR"
TS=$(date +%Y%m%d-%H%M%S)
DUMP_FILE="$DUMP_DIR/yfsp-$TS.h264"
LOG="$DUMP_DIR/yfsp-$TS.log"
> "$LOG"

export DISPLAY=:1
export XAUTHORITY=/run/user/1000/gdm/Xauthority
export MOZ_ENABLE_WAYLAND=0
export GDK_BACKEND=x11

# ╔══════════════════════════════════════════════════════════════════════╗
# ║  Phase 1 — 拿 CF cookie                                            ║
# ╚══════════════════════════════════════════════════════════════════════╝
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Phase 1 — 获取 cf_clearance（sandbox 正常 + 真实 UA）     ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# 每次都用全新 profile 起点，但若 cookie 已存在则复用
if [ ! -d "$PROFILE" ]; then
    mkdir -p "$PROFILE"
    PROFILE_NEW=1
else
    PROFILE_NEW=0
    # 检查现有 cookie
    CF_COUNT=$(sqlite3 "$PROFILE/cookies.sqlite" \
        "SELECT COUNT(*) FROM moz_cookies WHERE name='cf_clearance' AND expiry > strftime('%s','now')" 2>/dev/null || echo "0")
    if [ "$CF_COUNT" -gt 0 ]; then
        echo "✅ 检测到现有有效 cf_clearance cookie ($CF_COUNT 个，跳过 CF 验证)"
        echo "   直接进入 Phase 2..."
        # 直接进入 Phase 2
        unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
        unset MOZ_STREAM_DUMP_PATH
        # 修改 sandbox prefs 让 StreamDumper 能写文件
        PJS="$PROFILE/prefs.js"
        if [ -f "$PJS" ]; then
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
        rm -f "$PROFILE/.parentlock" "$PROFILE/parent.lock" "$PROFILE/lock"
        unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
        export MOZ_STREAM_DUMP_PATH="$DUMP_FILE"
        setsid nohup "$FF" -profile "$PROFILE" -no-remote --new-instance \
            "https://www.yfsp.tv/play/zImbBGABDR2" \
            < /dev/null >> "$LOG" 2>&1 &
        PHASE2_PID=$!
        disown
        echo "🚀 Firefox 已启动（PID=$PHASE2_PID），dump 到 $DUMP_FILE"
        # 监控
        LAST_SIZE=0
        STALL_COUNT=0
        while kill -0 "$PHASE2_PID" 2>/dev/null; do
            sleep 10
            if [ -f "$DUMP_FILE" ]; then
                SIZE=$(stat -c%s "$DUMP_FILE")
                if [ "$SIZE" -gt "$LAST_SIZE" ]; then
                    echo "  ✅ Dump: $(numfmt --to=iec $SIZE)"
                    LAST_SIZE=$SIZE
                    STALL_COUNT=0
                else
                    STALL_COUNT=$((STALL_COUNT+1))
                    if [ "$STALL_COUNT" -ge 6 ]; then
                        echo "  📦 60s 无增长，停止"
                        break
                    fi
                fi
            fi
        done
        # Post-processing
        OUT="${DUMP_FILE%.h264}.mp4"
        echo ""
        echo "📦 转 mp4: $OUT"
        ffmpeg -y -framerate 15 -i "$DUMP_FILE" -c:v copy -movflags +faststart "$OUT" 2>&1 | tail -3
        ls -lh "$OUT"
        exit 0
    fi
fi

# Phase 1 真实启动
if [ "$PROFILE_NEW" = "1" ] || [ "$CF_COUNT" = "0" ]; then
    echo "📦 新 profile: $PROFILE"
    rm -rf "$PROFILE"
    mkdir -p "$PROFILE"
fi

# **关键 user.js — 严禁这两条配置**
cat > "$PROFILE/user.js" << 'PJ'
// === Phase 1: sandbox 默认 + Firefox 真实 UA ===
// 严禁 general.useragent.override！会让 CF 把 Firefox 看作 bot
// 严禁 security.sandbox.*.level = 0！会让 CF Turnstile 拒绝发 cookie
user_pref("network.proxy.type", 5);                       // 走 GNOME 系统代理（Aurora SOCKS5）
user_pref("media.autoplay.default", 0);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.sessionstore.max_resumed_crashes", 0);
user_pref("browser.startup.page", 3);
user_pref("dom.webdriver.enabled", false);
user_pref("privacy.resistFingerprinting", false);
PJ

# 清残留锁
rm -f "$PROFILE/.parentlock" "$PROFILE/parent.lock" "$PROFILE/lock"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY MOZ_STREAM_DUMP_PATH

echo "🚀 启动 Firefox（Phase 1：sandbox 正常）..."
setsid nohup "$FF" \
    -profile "$PROFILE" \
    -no-remote --new-instance \
    "https://www.yfsp.tv/play/zImbBGABDR2" \
    < /dev/null > "$LOG" 2>&1 &
PHASE1_PID=$!
disown

# 拉窗口到前台
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1.5
    WID=$(XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
        xdotool search "Just a moment" 2>/dev/null | head -1)
    [ -z "$WID" ] && WID=$(XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
        xdotool search --classname "firefox-default" 2>/dev/null | head -1)
    [ -n "$WID" ] && {
        XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 xdotool windowsize "$WID" 1280 800 2>/dev/null
        XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 xdotool windowmove "$WID" 200 100 2>/dev/null
        XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 xdotool windowactivate "$WID" 2>/dev/null
        XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 xdotool windowraise "$WID" 2>/dev/null
        break
    }
done

echo ""
echo "┌──────────────────────────────────────────────────────────┐"
echo "│  👆  请手动通过 CF 人机验证                              │"
echo "│                                                          │"
echo "│  Firefox 通过验证后**会自动崩溃**（patched build WebGL   │"
echo "│  限制），崩溃后 cookie 已经落盘。脚本会自动检测。        │"
echo "│                                                          │"
echo "│  静默等待中，无须任何操作...                              │"
echo "└──────────────────────────────────────────────────────────┘"
echo ""

# 静默等待 Phase 1 Firefox 退出（30 分钟超时）
WAIT_TIMEOUT=1800
WAIT_START=$(date +%s)
while kill -0 "$PHASE1_PID" 2>/dev/null; do
    ELAPSED=$(($(date +%s) - WAIT_START))
    if [ $ELAPSED -gt $WAIT_TIMEOUT ]; then
        echo "⏰ 等待超时（$WAIT_TIMEOUT 秒），强制终止 Firefox"
        kill -9 "$PHASE1_PID" 2>/dev/null
        break
    fi
    sleep 10
done

# 杀掉可能自动恢复的 Firefox
for PID in $(ps -ef | grep -v grep | grep "$(basename $PROFILE)" | awk '{print $2}'); do
    EXE=$(readlink -f /proc/$PID/exe 2>/dev/null)
    if echo "$EXE" | grep -q "firefox-stream-fetch"; then
        kill -9 "$PID" 2>/dev/null
    fi
done
sleep 2
rm -f "$PROFILE/.parentlock" "$PROFILE/parent.lock" "$PROFILE/lock"

# 检测 cookie
CF_COUNT=$(sqlite3 "$PROFILE/cookies.sqlite" \
    "SELECT COUNT(*) FROM moz_cookies WHERE name='cf_clearance'" 2>/dev/null || echo "0")
if [ "$CF_COUNT" -eq 0 ]; then
    echo ""
    echo "❌ 未检测到 cf_clearance cookie"
    echo "   可能原因："
    echo "   - 你没有完成 CF 验证"
    echo "   - Firefox 崩溃时 cookie 还未落盘"
    echo "   重新跑一次脚本即可再试。"
    exit 1
fi
echo ""
echo "✅ Phase 1 完成 — cf_clearance cookie 已落盘（$CF_COUNT 个）"
echo ""

# ╔══════════════════════════════════════════════════════════════════════╗
# ║  Phase 2 — StreamDumper 抓取                                        ║
# ╚══════════════════════════════════════════════════════════════════════╝
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Phase 2 — StreamDumper 抓取（sandbox 关闭）              ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# 关 sandbox，让 StreamDumper 能写文件
PJS="$PROFILE/prefs.js"
if [ -f "$PJS" ]; then
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
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY

echo "📦 Dump: $DUMP_FILE"
echo "🚀 重启 Firefox（Phase 2：sandbox 关闭）..."
setsid nohup "$FF" \
    -profile "$PROFILE" \
    -no-remote --new-instance \
    "https://www.yfsp.tv/play/zImbBGABDR2" \
    < /dev/null >> "$LOG" 2>&1 &
PHASE2_PID=$!
disown

# 拉窗口
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1.5
    WID=$(XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
        xdotool search --classname "firefox-default" 2>/dev/null | head -1)
    [ -n "$WID" ] && {
        XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 xdotool windowsize "$WID" 1280 800 2>/dev/null
        XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 xdotool windowmove "$WID" 400 150 2>/dev/null
        XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 xdotool windowactivate "$WID" 2>/dev/null
        XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 xdotool windowraise "$WID" 2>/dev/null
        break
    }
done

# 监控 dump
LAST_SIZE=0
STALL_COUNT=0
echo ""
echo "  ⏳ 监控 dump（每 10 秒）..."

while kill -0 "$PHASE2_PID" 2>/dev/null; do
    sleep 10
    if [ -f "$DUMP_FILE" ]; then
        SIZE=$(stat -c%s "$DUMP_FILE")
        if [ "$SIZE" -gt "$LAST_SIZE" ]; then
            DELTA=$((SIZE - LAST_SIZE))
            echo "  ✅ $(numfmt --to=iec $SIZE)  (+$(numfmt --to=iec $DELTA))"
            LAST_SIZE=$SIZE
            STALL_COUNT=0
        else
            STALL_COUNT=$((STALL_COUNT+1))
            if [ "$STALL_COUNT" -ge 12 ]; then
                echo "  📦 120s 无增长，停止（视频可能已播完）"
                kill -15 "$PHASE2_PID" 2>/dev/null
                break
            fi
        fi
    else
        echo "  ⏳ 暂无 dump（等待视频加载）"
    fi
done

# ╔══════════════════════════════════════════════════════════════════════╗
# ║  后处理 — mp4 封装                                                  ║
# ╚══════════════════════════════════════════════════════════════════════╝
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  最终结果"
echo "════════════════════════════════════════════════════════════"
if [ -f "$DUMP_FILE" ]; then
    OUT="${DUMP_FILE%.h264}.mp4"
    echo ""
    echo "📦 H.264 dump: $(ls -lh $DUMP_FILE | awk '{print $5}')"
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
else
    echo "❌ 无 dump 文件"
    echo "日志: $LOG"
    echo ""
    grep "StreamDumper" "$LOG" | head -5
fi