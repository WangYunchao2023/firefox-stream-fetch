#!/bin/bash
# 下载 Firefox 源码 (gecko-dev GitHub 镜像,浅克隆)
set -e

TARGET_DIR="${1:-./firefox}"
REPO="https://github.com/mozilla/gecko-dev.git"

if [ -d "$TARGET_DIR" ]; then
  echo "已存在 $TARGET_DIR,跳过"
  exit 0
fi

echo "克隆 gecko-dev 到 $TARGET_DIR ..."
git clone --depth=1 "$REPO" "$TARGET_DIR"
echo "完成。占用空间:"
du -sh "$TARGET_DIR"
