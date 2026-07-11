#!/bin/bash
# 检查 YUV dump 状态 + 播放
# 用法: bash check-dump.sh [path/to/dump.yuv]
set -e

DUMP="${1:-/tmp/moz_dump.yuv}"
META="${DUMP}.meta"

echo "=== Dump 文件状态 ==="
ls -lh "$DUMP" 2>&1 | head -2
ls -lh "$META" 2>&1 | head -2
echo ""

# 读 .meta
if [ -f "$META" ]; then
  echo "=== 元数据 ==="
  cat "$META"
  echo ""
  WIDTH=$(grep -E "^width" "$META" | cut -f2)
  HEIGHT=$(grep -E "^height" "$META" | cut -f2)
  echo ""
  echo "分辨率: ${WIDTH}x${HEIGHT}"
  echo ""

  # 计算帧数
  if [ -n "$WIDTH" ] && [ -n "$HEIGHT" ] && [ -f "$DUMP" ]; then
    FRAME_SIZE=$((WIDTH * HEIGHT * 3 / 2))  # I420 = Y + U/4 + V/4
    FILE_SIZE=$(stat -c%s "$DUMP")
    FRAME_COUNT=$((FILE_SIZE / FRAME_SIZE))
    REMAIN=$((FILE_SIZE % FRAME_SIZE))
    echo "文件大小: $FILE_SIZE bytes"
    echo "每帧大小: $FRAME_SIZE bytes (${WIDTH}x${HEIGHT} I420)"
    echo "估算帧数: $FRAME_COUNT (余 $REMAIN bytes)"
    echo ""

    if [ $FRAME_COUNT -gt 0 ] && command -v ffplay >/dev/null 2>&1; then
      echo "=== 准备播放 ==="
      echo "按 Ctrl+C 退出"
      echo ""
      sleep 2
      ffplay -f rawvideo -pix_fmt yuv420p -s "${WIDTH}x${HEIGHT}" -i "$DUMP"
    fi
  fi
else
  echo "❌ 没找到 $META"
  echo "   还没生成 dump? 检查:"
  echo "   - Firefox 启动时是否设了 MOZ_DUMP_VIDEO_FRAMES=1"
  echo "   - 是否播放了视频 (有些网站要等几秒)"
  echo "   - 看 Firefox stderr: 'YUVDumper: writing to ...'"
fi
