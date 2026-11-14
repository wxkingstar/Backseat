#!/bin/bash
# 编译并启动 Mac 端 bridge（前台运行，Ctrl+C 退出）
set -e
cd "$(dirname "$0")/../mac"
swift build -c release 2>&1 | tail -1
exec .build/release/backseat
