#!/bin/bash
# Firefox 构建依赖安装脚本
# 用户手动跑一次: sudo bash install-deps.sh
set -e

echo "=== 1. 系统包 (Ubuntu 22.04) ==="
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
  python3-venv \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  libxcb-randr0-dev libxcb-glx0-dev libxcb-xfixes0-dev libxcb-xkb1-dev \
  libxcb-shape0-dev libxcb-xinput0-dev libxkbcommon-x11-dev \
  mesa-common-dev libosmesa6-dev \
  libnss3-dev libnspr4-dev \
  autoconf2.13 yasm nasm \
  libpulse-dev libasound2-dev

echo ""
echo "=== 2. Rust 工具链 (Firefox 编译需要) ==="
if ! command -v rustc >/dev/null 2>&1; then
  echo "装 rustup..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain none
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi
echo "rustc: $(rustc --version 2>&1 | head -1)"
echo "cargo: $(cargo --version 2>&1 | head -1)"

echo ""
echo "=== 3. 装 cbindgen (Firefox bindgen 工具) ==="
if ! command -v cbindgen >/dev/null 2>&1; then
  cargo install cbindgen --locked
fi
echo "cbindgen: $(cbindgen --version)"

echo ""
echo "=== 完成 ==="
echo "接下来跑:"
echo "  cd ~/Documents/软件类工作/firefox-re/firefox"
echo "  ./mach bootstrap    # 提示时选 Firefox (modern)"
echo "  ./mach build        # 编译,大约 30-60 分钟"
