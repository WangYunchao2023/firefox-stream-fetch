#!/bin/bash
# 启动修改后的 Firefox (抓取解密后、解码前的 H.264 流)
# 用法: bash run-stream.sh [可选:Profile 目录]
set -e

PROJECT_DIR="/home/wangyc/Documents/软件类工作/firefox-stream-fetch"

# Profile
PROFILE_DIR="${1:-/tmp/firefox-stream-profile}"
mkdir -p "$PROFILE_DIR"

# dump 输出
DUMP_DIR="/tmp/moz_stream_dumps"
mkdir -p "$DUMP_DIR"
DUMP_FILE="$DUMP_DIR/$(date +%Y%m%d-%H%M%S).h264"

# 找编译产物
FIREFOX_BIN=$(find "$PROJECT_DIR/obj-stream" -name "firefox" -type f 2>/dev/null | head -1)
if [ -z "$FIREFOX_BIN" ]; then
  FIREFOX_BIN=$(find "$PROJECT_DIR/obj-stream" -name "firefox-bin" -type f 2>/dev/null | head -1)
fi
if [ -z "$FIREFOX_BIN" ]; then
  echo "❌ 找不到 firefox 二进制，需要先 ./mach build 完成"
  echo "   试: find $PROJECT_DIR -name 'firefox*' -type f 2>/dev/null"
  exit 1
fi
FIREFOX_DIR=$(dirname "$FIREFOX_BIN")
echo "✅ 找到 Firefox: $FIREFOX_BIN"

# 安装 Widevine
if [ ! -d "$FIREFOX_DIR/widevine" ]; then
  echo "=== 安装 Widevine CDM ==="
  WIDEVINE_SRC="$PROJECT_DIR/firefox-dist/widevine"
  if [ -d "$WIDEVINE_SRC" ]; then
    cp -r "$WIDEVINE_SRC" "$FIREFOX_DIR/widevine"
    echo "✅ Widevine 已安装到 Firefox 目录"
  else
    echo "⚠️  找不到 $WIDEVINE_SRC"
  fi
fi

# 清理旧 dump
rm -f "$DUMP_FILE"

# 启动 Firefox
echo ""
echo "=== 启动 Firefox ==="
echo "Profile:  $PROFILE_DIR"
echo "Stream dump: $DUMP_FILE"
echo ""

# 关键：设置 dump 路径环境变量（StreamDumper::Dump 会读取）
export MOZ_STREAM_DUMP_PATH="$DUMP_FILE"

# 禁用不必要的启动特性
export MOZ_ENABLE_WAYLAND=0
export MOZ_DISABLE_SAFE_MODE_KEY=1

# 禁用 RDD 沙箱（确保 FFmpeg 解码器能跑通）
# 注：StreamDumper 在 RDD 之前 hook，但解密的 NALU 数据要传到解码器
export MOZ_DISABLE_RDD_SANDBOX=1

# 启动
"$FIREFOX_BIN" \
  -profile "$PROFILE_DIR" \
  -no-remote \
  --new-instance \
  "about:blank" &

FF_PID=$!
echo ""
echo "Firefox PID: $FF_PID"
echo ""
echo "运行后:"
echo "  1. 打开 Widevine L3 内容（如支持 L3 的视频站）"
echo "  2. 播放一段时间"
echo "  3. 关闭 Firefox 后，到 $DUMP_DIR 找 .h264 文件"
echo "  4. 用 ffplay 验证："
echo "     ffplay -f h264 -i $DUMP_FILE"
echo "  5. 或转封装成 mp4："
echo "     ffmpeg -f h264 -i $DUMP_FILE -c copy $DUMP_FILE.mp4"
echo ""
echo "也可以实时观察 dump 进度："
echo "  watch -n 1 'ls -la $DUMP_FILE; tail -10 /home/wangyc/.cache/moz_stream.log 2>/dev/null'"
