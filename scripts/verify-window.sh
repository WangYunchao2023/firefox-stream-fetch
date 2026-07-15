#!/bin/bash
# verify-window.sh: 验证 capture-generic.sh 的 firefox 启动方式能否创建可见窗口
#
# 复制 capture-generic.sh 的启动方式（env 变量 + firefox 二进制 + 启动参数）
# 加载 about:blank，然后用 xdotool / wmctrl 检查：
#   - xdotool search 能否找到 "Nightly" 窗口
#   - 窗口标题、几何位置、是否被 manage
#
# 如果找不到窗口 = 根因不是 wayland，是更深的问题
# 如果找到 = MOZ_ENABLE_WAYLAND=0 + GDK_BACKEND=x11 修复生效
set -e

PROJECT="/home/wangyc/Documents/软件类工作/firefox-stream-fetch"
PROFILE="/tmp/firefox-window-verify-profile"
LOG="/tmp/moz_stream_dumps/window-verify.log"

rm -rf "$PROFILE"
mkdir -p "$PROFILE"
mkdir -p "$(dirname "$LOG")"

cat > "$PROFILE/user.js" << 'PJ'
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.shell.skipDefaultBrowserCheckOnFirstRun", true);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.messaging-system.whatsNewPanel.enabled", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
PJ

# 检查依赖
for cmd in xdotool xwininfo; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "❌ 缺 $cmd：sudo apt install xdotool x11-utils"
        exit 1
    fi
done
HAS_WMCTRL=0
command -v wmctrl &>/dev/null && HAS_WMCTRL=1

FF=$(find -L "$PROJECT/obj-stream" -path "*dist/bin/firefox" -type f -executable 2>/dev/null | head -1)
[ -z "$FF" ] && { echo "❌ 找不到 firefox"; exit 1; }
FF_DIR=$(dirname "$FF")
echo "✅ Firefox: $FF"

# Widevine
if [ ! -d "$FF_DIR/widevine" ]; then
    SRC="$PROJECT/firefox-dist/widevine"
    [ -d "$SRC" ] && cp -r "$SRC" "$FF_DIR/widevine" && echo "✅ Widevine 部署"
fi

# === 关键：跟 capture-generic.sh 完全相同的 env 变量 ===
export DISPLAY=:1
export XAUTHORITY=/run/user/1000/gdm/Xauthority
export MOZ_ENABLE_WAYLAND=0
export GDK_BACKEND=x11
export MOZ_DISABLE_RDD_SANDBOX=1

> "$LOG"

echo ""
echo "=== 启动 firefox（env：DISPLAY=$DISPLAY MOZ_ENABLE_WAYLAND=$MOZ_ENABLE_WAYLAND GDK_BACKEND=$GDK_BACKEND）==="

setsid nohup "$FF" \
    -profile "$PROFILE" \
    -no-remote --new-instance \
    "about:blank" \
    < /dev/null > "$LOG" 2>&1 &
FF_PID=$!
disown

echo "Firefox PID: $FF_PID"

# === 轮询等待窗口出现（最多 30 秒）===
echo ""
echo "=== 等待窗口出现（最多 30s，每 2s 检查）==="
FOUND=0
WID=""
for i in $(seq 1 15); do
    sleep 2
    # xdotool search 找 "Nightly"（custom-built firefox 用 official branding, CodeName=Nightly）
    WID=$(XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
        xdotool search --name "Nightly" 2>/dev/null | head -1)
    if [ -n "$WID" ]; then
        echo "  ✅ 第 $((i*2))s 找到窗口：WID=$WID"
        FOUND=1
        break
    else
        echo "  ⏳ 第 $((i*2))s 暂无窗口..."
    fi
done

echo ""
echo "=== 结果 ==="
if [ $FOUND -eq 0 ]; then
    echo "❌ FAIL: 30 秒内未找到 'Nightly' 窗口"
    echo ""
    echo "--- firefox log 头部 ---"
    head -20 "$LOG"
    echo ""
    echo "--- 进程状态 ---"
    if kill -0 $FF_PID 2>/dev/null; then
        echo "firefox 进程 $FF_PID 还在跑（说明没 crash，但窗口没创建）"
    else
        echo "firefox 进程已退出"
    fi
    pkill -f "firefox.*window-verify-profile" 2>/dev/null || true
    exit 1
fi

# === 窗口详情 ===
TITLE=$(XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
    xdotool getwindowname "$WID" 2>/dev/null)
PID=$(XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
    xdotool getwindowpid "$WID" 2>/dev/null)
GEOM=$(XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
    xdotool getwindowgeometry "$WID" 2>/dev/null | grep -E "Position|Geometry" | head -2)

echo "✅ SUCCESS: 窗口已创建并被 WM manage"
echo "  WID:    $WID"
echo "  Title:  $TITLE"
echo "  PID:    $PID (我们启动的 $FF_PID)"
echo "  Geom:   $GEOM"
echo ""

# 试 xdotool windowactivate + windowraise 把窗口拉到前台（模拟 pull_window_front）
XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
    xdotool windowactivate "$WID" 2>&1
XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 \
    xdotool windowraise "$WID" 2>&1
echo "  windowactivate + windowraise 执行成功"
echo ""

# wmctrl 列表确认（如果装了）
if [ $HAS_WMCTRL -eq 1 ]; then
    echo "--- wmctrl -l (跟其他窗口对比) ---"
    XAUTHORITY=/run/user/1000/gdm/Xauthority DISPLAY=:1 wmctrl -l 2>/dev/null | head -10
else
    echo "--- wmctrl 未安装（略过 wmctrl -l 验证，仅靠 xdotool 已足够） ---"
fi

echo ""
echo "--- StreamDumper / Gdk-CRITICAL 警告检查 ---"
if grep -q "Gdk-CRITICAL\|gdk_window_get_position" "$LOG"; then
    GDK_COUNT=$(grep -c "Gdk-CRITICAL\|gdk_window_get_position" "$LOG")
    echo "  ⚠️  log 里有 $GDK_COUNT 条 Gdk 警告（窗口出现了但有 race）"
else
    echo "  ✅ log 里无 Gdk-CRITICAL warning（修复生效）"
fi

if grep -q "StreamDumper" "$LOG"; then
    echo "  (log 里也包含 StreamDumper 输出 — 跟窗口无关)"
fi

# 关闭 firefox
echo ""
echo "--- 关闭 firefox ---"
kill -15 $FF_PID 2>/dev/null
sleep 2
kill -9 $FF_PID 2>/dev/null
rm -rf "$PROFILE" /tmp/parent.lock 2>/dev/null
echo "清理完成"