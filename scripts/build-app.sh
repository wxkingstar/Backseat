#!/bin/bash
# 把 Mac 端打包成菜单栏 App：build/Backseat.app
# 默认本机临时签名（只适合自己用）。要分发给别人：BACKSEAT_SIGN_ID="Developer ID Application: …" bash scripts/build-app.sh，再公证。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Backseat.app"

cd "$ROOT/mac"
# 通用二进制：Apple 芯片和 Intel 的 Mac 都能打开
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}" 2>&1 | grep -v "is deprecated" | tail -1
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/backseat" "$APP/Contents/MacOS/Backseat"
cp "$ROOT/mac/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>dev.backseat.mac</string>
	<key>CFBundleName</key>
	<string>Backseat</string>
	<key>CFBundleExecutable</key>
	<string>Backseat</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>NSLocalNetworkUsageDescription</key>
	<string>让同一个 Wi-Fi 下的 iPhone 和 Apple Watch 找到并连上这台 Mac。</string>
	<key>NSBonjourServices</key>
	<array>
		<string>_backseat._tcp</string>
	</array>
	<key>CFBundleShortVersionString</key>
	<string>1.0.3</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSAudioCaptureUsageDescription</key>
	<string>把手表和手机传来的声音送进虚拟麦克风，交给语音输入法识别。不会录制其他 App 的声音。</string>
	<key>NSSpeechRecognitionUsageDescription</key>
	<string>没有安装语音输入法时，用 Mac 内置识别把你说的话转成文字。</string>
</dict>
</plist>
EOF

if [ -n "${BACKSEAT_SIGN_ID:-}" ]; then
  ENT="$(mktemp)"
  cat > "$ENT" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.device.audio-input</key>
	<true/>
</dict>
</plist>
EOF
  codesign --force --timestamp --options runtime --entitlements "$ENT" --sign "$BACKSEAT_SIGN_ID" "$APP"
  rm -f "$ENT"
else
  codesign --force --sign - "$APP"
fi
echo "已生成 $APP"
