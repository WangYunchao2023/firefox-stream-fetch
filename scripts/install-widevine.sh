#!/bin/bash
# 把抠出的 Widevine CDM 安装到自定义 Firefox 目录
# 用法: bash install-widevine.sh /path/to/firefox-dist
set -e

FIREFOX_DIST="${1:?用法: $0 /path/to/firefox-dist}"
WIDEVINE_SRC="/opt/google/chrome/WidevineCdm"
DEST="$FIREFOX_DIST/widevine"

if [ ! -d "$WIDEVINE_SRC" ]; then
  echo "错误: 找不到 Chrome 的 WidevineCdm,需要先装 Chrome"
  exit 1
fi

mkdir -p "$DEST"
cp -r "$WIDEVINE_SRC"/* "$DEST/"
echo "✅ Widevine CDM 已安装到 $DEST"
ls -la "$DEST/_platform_specific/linux_x64/" | head -3
