#!/bin/bash
# 验证 dump 出来的 H.264 文件 - 用 ffprobe 看格式，用 ffplay 试播
# 用法: bash check-stream.sh [dump.h264]
set -e

PROJECT_DIR="/home/wangyc/Documents/软件类工作/firefox-stream-fetch"

DUMP_FILE="${1:-/tmp/moz_stream.h264}"

if [ ! -f "$DUMP_FILE" ]; then
  echo "❌ 找不到 $DUMP_FILE"
  echo "   先跑: bash $PROJECT_DIR/scripts/run-stream.sh"
  exit 1
fi

# 可能在新 dumps 目录
NEW_DUMPS=$(ls -t /tmp/moz_stream_dumps/*.h264 2>/dev/null | head -1)
if [ -n "$NEW_DUMPS" ] && [ "$NEW_DUMPS" -nt "$DUMP_FILE" ]; then
  DUMP_FILE="$NEW_DUMPS"
  echo "使用最新的 dump: $DUMP_FILE"
fi

SIZE=$(stat -c %s "$DUMP_FILE")
SIZE_MB=$(echo "scale=1; $SIZE/1024/1024" | bc)
echo "================================================"
echo "📁 文件:   $DUMP_FILE"
echo "📊 大小:   ${SIZE_MB} MB (${SIZE} bytes)"
echo "================================================"
echo ""

# 1. 文件签名 - 检查是否真有 H.264 起始码
echo "=== 检查前 64 字节（应该看到 Annex B start code 00 00 00 01） ==="
xxd "$DUMP_FILE" | head -4
echo ""

# 2. SPS/PPS 查找 - 第一个 NAL unit 应该是 00 00 00 01 67 (SPS) 或 00 00 00 01 27 (SPS for AVC, also 67 = 0b01100111)
# 67 = nal_unit_type=7 (SPS), 0x67 = 0x67
# 68 = nal_unit_type=8 (PPS), 0x68 = 0x68
# 41 = nal_unit_type=1 (non-IDR slice), typical for video data
SPS_COUNT=$(grep -c -aP '\x00\x00\x00\x01\x67|\x00\x00\x01\x67' "$DUMP_FILE" 2>/dev/null || echo 0)
PPS_COUNT=$(grep -c -aP '\x00\x00\x00\x01\x68|\x00\x00\x01\x68' "$DUMP_FILE" 2>/dev/null || echo 0)
IDR_COUNT=$(grep -c -aP '\x00\x00\x00\x01[\x65-\x67]|\x00\x00\x01[\x65-\x67]' "$DUMP_FILE" 2>/dev/null || echo 0)

echo "=== H.264 NALU 统计 (Annex B start codes) ==="
echo "  SPS (0x67/0x27):  $SPS_COUNT 处"
echo "  PPS (0x68/0x28):  $PPS_COUNT 处"
echo "  IDR (0x25/0x45/0x65): $IDR_COUNT 处"
echo ""

# 3. 用 ffprobe 检查
echo "=== ffprobe 分析 ==="
if which ffprobe > /dev/null 2>&1; then
  ffprobe -v error -hide_banner \
    -show_format -show_streams \
    -of default=nw=1 "$DUMP_FILE" 2>&1 | head -30
  echo ""
  echo "duration / bit_rate（如有）："
  ffprobe -v error -hide_banner -show_entries format=duration,size,bit_rate -of default=nw=1 "$DUMP_FILE"
else
  echo "❌ 找不到 ffprobe，请装 ffmpeg"
fi
echo ""

# 4. 估算帧数（粗略）
NAL_COUNT=$(grep -c -aP '\x00\x00\x00\x01' "$DUMP_FILE" 2>/dev/null || echo 0)
echo "=== 总 NALU 数量（00 00 00 01 起始）: $NAL_COUNT ==="
echo "  ≈ $NAL_COUNT NALUs (SPS/PPS/SEI + 每帧 1 个 slice)"
echo ""

# 5. 转换/重封装 mp4
echo "=== 转封装选项 ==="
echo ""
echo "如果你确认 dump 内容有效，可以转封装成 mp4："
echo ""
echo "  ffmpeg -f h264 -i $DUMP_FILE -c copy $DUMP_FILE.mp4"
echo ""
echo "（这样可以用 mpv / VLC / 各种播放器直接打开）"
echo ""

# 6. 播放预览
echo "=== ffplay 预览 ==="
if which ffplay > /dev/null 2>&1; then
  echo "  运行预览（在窗口中按 q 退出）："
  echo "  ffplay -f h264 -loglevel warning -infbuf -autoexit $DUMP_FILE"
  echo ""
  read -p "  现在播放？(y/N) " answer
  if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
    echo ""
    echo "启动 ffplay..."
    timeout 15 ffplay -f h264 -loglevel warning -autoexit "$DUMP_FILE" 2>&1 | head -10 || true
  fi
else
  echo "❌ 找不到 ffplay"
fi

echo ""
echo "================================================"
echo "验证结束"
echo "================================================"
