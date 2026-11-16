#!/bin/bash
# 编译回环声卡驱动：build/BackseatMic.driver
# 默认本机临时签名。要分发给别人：BACKSEAT_SIGN_ID="Developer ID Application: …" bash scripts/build-driver.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRIVER="$ROOT/build/BackseatMic.driver"

rm -rf "$DRIVER"
mkdir -p "$DRIVER/Contents/MacOS"
cp "$ROOT/mac/Driver/Info.plist" "$DRIVER/Contents/Info.plist"
clang -Wall -Wextra -O2 -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
  -framework CoreAudio -framework CoreFoundation \
  -o "$DRIVER/Contents/MacOS/BackseatMic" "$ROOT/mac/Driver/BackseatMic.c"

if [ -n "${BACKSEAT_SIGN_ID:-}" ]; then
  codesign --force --timestamp --options runtime --sign "$BACKSEAT_SIGN_ID" "$DRIVER"
else
  codesign --force --sign - "$DRIVER"
fi
echo "已生成 $DRIVER"
