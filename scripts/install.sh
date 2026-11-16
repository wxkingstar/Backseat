#!/bin/bash
# 一条命令装好并启动 Mac 端：下载源码（如果还没有）→ 编译 → 安装 → 启动。
# 中途只需要输一次开机密码（把菜单栏 App 和虚拟声卡装进系统）。重复运行就是升级。
#
#   curl -fsSL https://raw.githubusercontent.com/wxkingstar/Backseat/main/scripts/install.sh | bash
#
# 已经 clone 了仓库的话，直接运行 bash scripts/install.sh。
set -euo pipefail

if ! xcode-select -p >/dev/null 2>&1; then
  echo "需要先装 Xcode 命令行工具：运行 xcode-select --install，装好后重新运行本脚本。"
  exit 1
fi

# 从仓库里运行就用这份源码；通过 curl 运行时把源码放到 ~/.backseat/src
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")/.." 2>/dev/null && pwd || true)"
if [ ! -f "$ROOT/mac/Package.swift" ]; then
  ROOT="$HOME/.backseat/src"
  if [ -d "$ROOT/.git" ]; then
    echo "更新源码…"
    git -C "$ROOT" pull --ff-only --quiet
  else
    echo "下载源码…"
    mkdir -p "$(dirname "$ROOT")"
    git clone --depth 1 --quiet https://github.com/wxkingstar/Backseat.git "$ROOT"
  fi
fi

echo "编译中（第一次大约一两分钟）…"
bash "$ROOT/scripts/build-pkg.sh"

echo "安装到系统，需要输入开机密码（声音会断一两秒）…"
sudo installer -pkg "$ROOT/build/Backseat.pkg" -target / </dev/tty

# 已经在运行的旧版本先退出，再打开新装的
pkill -x Backseat 2>/dev/null || true
open /Applications/Backseat.app

cat <<'EOF'

装好了，菜单栏里会出现 Backseat 的图标（尖括号里一支麦克风）。
接下来：
  1. 第一次启动会弹「辅助功能」授权：系统设置 → 隐私与安全性 → 辅助功能，打开 Backseat。
  2. 点菜单栏的 Backseat 图标，能看到 4 位配对码，在手机 / 手表 App 里输入。
EOF
