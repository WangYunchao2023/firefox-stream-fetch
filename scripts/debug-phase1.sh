#!/bin/bash
# Phase 1 检测逻辑诊断脚本 - 修复版

PROFILE="/tmp/firefox-stream-debug-phase1"
URL="https://www.yfsp.tv/play/zImbBGABDR2"

export DISPLAY=:1
export XAUTHORITY=/run/user/1000/gdm/Xauthority

get_firefox_wid() {
    local wid
    wid=$(xdotool search --classname "firefox-default" 2>/dev/null | head -1)
    if [ -z "$wid" ]; then
        wid=$(xdotool search --name "Firefox" 2>/dev/null | head -1)
    fi
    echo "$wid"
}

get_firefox_title() {
    local WID="$1"
    [ -n "$WID" ] && xdotool getwindowname "$WID" 2>/dev/null
}

pull_window_front() {
    local WID="$1"
    XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
        xdotool windowsize "$WID" 1280 800 2>/dev/null
    XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
        xdotool windowmove "$WID" 200 100 2>/dev/null
    XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
        xdotool windowactivate "$WID" windowraise "$WID" 2>/dev/null
}

echo "=== Phase 1 检测逻辑诊断 ==="
echo "目标 URL: $URL"
echo "请在 Firefox 中手动打开该 URL 并完成 CF 验证、开始播放"
echo "脚本会每 2 秒轮询窗口标题，显示判断依据"
echo ""

read -p "Firefox 已打开且在目标页面？按 Enter 开始轮询..."

WID=$(get_firefox_wid)
if [ -z "$WID" ]; then
    echo "❌ 找不到 Firefox 窗口"
    exit 1
fi
echo "监控窗口 WID: $WID"
pull_window_front "$WID"
echo ""

elapsed=0
saw_cf=0
phase1_triggered=0

while [ "$elapsed" -lt 300 ]; do
    sleep 2
    elapsed=$((elapsed + 2))
    if [ $((elapsed % 10)) -eq 0 ]; then
        pull_window_front "$WID"
    fi
    title=$(get_firefox_title "$WID")
    if [ -z "$title" ]; then
        echo "[$elapsed s] 标题为空（窗口可能最小化或失焦）"
        continue
    fi
    
    if echo "$title" | grep -qi "Just a moment"; then
        if [ "$saw_cf" -eq 0 ]; then
            echo "[$elapsed s] ⏳ 检测到 CF 挑战页: '$title'"
            saw_cf=1
        else
            echo "[$elapsed s] ⏳ CF 挑战中... '$title'"
        fi
    elif [ "$title" != "Nightly" ] && [ "$title" != "Firefox" ] && [ "$title" != "New Tab" ]; then
        echo "[$elapsed s] ✅ 触发 Phase 1 结束条件！标题: '$title'"
        echo "   判断依据: 非默认标题，且不包含 'Just a moment'"
        phase1_triggered=1
        break
    else
        echo "[$elapsed s] 标题: '$title'（默认/空白页，继续等待）"
    fi
done

if [ "$phase1_triggered" -eq 1 ]; then
    echo ""
    echo "=== 如果此时 SIGTERM Firefox，检查 cookie 落盘情况 ==="
    sleep 2
    if [ -f "$PROFILE/cookies.sqlite" ]; then
        CF_COUNT=$(sqlite3 "$PROFILE/cookies.sqlite" \
            "SELECT COUNT(*) FROM moz_cookies WHERE name='cf_clearance' AND expiry > strftime('%s','now')" 2>/dev/null || echo 0)
        echo "cf_clearance 条数: $CF_COUNT"
        if [ "$CF_COUNT" -gt 0 ]; then
            echo "✅ Cookie 已落盘，Phase 2 可启动"
        else
            echo "❌ Cookie 未落盘（Firefox 异步写入，可能需要更久或显式 flush）"
        fi
    else
        echo "❌ cookies.sqlite 不存在"
    fi
else
    echo ""
    echo "⚠️  5 分钟内未触发 Phase 1 结束条件"
    echo "可能原因："
    echo "  1. 视频播放后标题未变化（某些播放器不更新 title）"
    echo "  2. 标题包含其他关键词导致误判"
    echo "  3. 窗口未聚焦导致 xdotool 取不到标题"
fi

# 清理
pkill -f "firefox.*firefox-debug-phase1" 2>/dev/null
