#!/bin/bash
# 启动自定义 Firefox,启用 YUV dump
# 用法: bash run-firefox.sh [profile-dir]
set -e

# 默认 profile (避免污染系统 default profile)
PROFILE_DIR="${1:-/tmp/firefox-dump-profile}"
mkdir -p "$PROFILE_DIR"

# dump 输出路径
DUMP_PATH="/tmp/moz_dump.yuv"
DUMP_DIR="/tmp/moz_dumps"
mkdir -p "$DUMP_DIR"
DUMP_FILE="$DUMP_DIR/$(date +%Y%m%d-%H%M%S).yuv"

# YUV 播放器 (确认可用)
FFPLAY=$(which ffplay 2>/dev/null || echo "")
if [ -n "$FFPLAY" ]; then
  echo "ffplay: $FFPLAY"
else
  echo "警告: 找不到 ffplay,需要装 ffmpeg (sudo apt install ffmpeg)"
fi

# 找编译产物
FIREFOX_BIN=$(find /home/wangyc/Documents/软件类工作/firefox-re/firefox/obj-*/dist -name "firefox" -type f 2>/dev/null | head -1)
if [ -z "$FIREFOX_BIN" ]; then
  # 备选: 找 firefox-bin
  FIREFOX_BIN=$(find /home/wangyc/Documents/软件类工作/firefox-re/firefox/obj-*/dist -name "firefox-bin" -type f 2>/dev/null | head -1)
fi
if [ -z "$FIREFOX_BIN" ]; then
  echo "❌ 找不到编译产物,等 ./mach build 完成后才有"
  echo "   试: find /home/wangyc/Documents/软件类工作/firefox-re/firefox -name 'firefox*' -type f 2>/dev/null"
  exit 1
fi
FIREFOX_DIR=$(dirname "$FIREFOX_BIN")
echo "✅ 找到 Firefox: $FIREFOX_BIN"

# 抠 Widevine CDM
if [ ! -d "$FIREFOX_DIR/widevine" ]; then
  echo "=== 安装 Widevine CDM ==="
  WIDEVINE_SRC="/opt/google/chrome/WidevineCdm"
  if [ -d "$WIDEVINE_SRC" ]; then
    cp -r "$WIDEVINE_SRC" "$FIREFOX_DIR/widevine"
    echo "✅ Widevine 已安装"
  else
    echo "⚠️  找不到 Chrome 的 WidevineCdm,跳过"
  fi
fi

# 启动 Firefox
echo ""
echo "=== 启动 Firefox ==="
echo "Profile:  $PROFILE_DIR"
echo "Dump to:  $DUMP_FILE"
echo "Meta to:  $DUMP_FILE.meta"
echo ""

# 清理旧 dump
rm -f "$DUMP_FILE" "$DUMP_FILE.meta"

# 关键: 设置 dump 环境变量
export MOZ_DUMP_VIDEO_FRAMES=1
export MOZ_DUMP_VIDEO_PATH="$DUMP_FILE"

# 禁用不必要功能以加快启动
export MOZ_ENABLE_WAYLAND=0
export MOZ_DISABLE_SAFE_MODE_KEY=1

# 用 firefox -profile 启动
"$FIREFOX_BIN" \
  -profile "$PROFILE_DIR" \
  -no-remote \
  --new-instance \
  "about:blank" &

FF_PID=$!
echo ""
echo "Firefox PID: $FF_PID"
echo "运行后:"
echo "  1. 在 Firefox 里打开 Widevine 内容 (如 bilibili 大会员/YouTube Premium)"
echo "  2. 播放一段时间"
echo "  3. 在另一个终端跑:"
echo "     bash /home/wangyc/Documents/软件类工作/firefox-re/scripts/check-dump.sh $DUMP_FILE"
echo "  4. 关闭 Firefox 后,看 /tmp/moz_dumps/ 下的 yuv 文件"
