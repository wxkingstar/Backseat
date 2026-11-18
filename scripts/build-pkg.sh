#!/bin/bash
# 做一体安装包：build/Backseat.pkg
# 装的东西：/Applications/Backseat.app（菜单栏 App）和 /Library/Audio/Plug-Ins/HAL/BackseatMic.driver（回环声卡）。
# 装完自动重启系统的音频服务，声卡马上可用，不用重启电脑。
# 要分发给别人，App 和驱动用 BACKSEAT_SIGN_ID（Developer ID Application）签名，
# 安装包用 BACKSEAT_INSTALLER_ID（Developer ID Installer）签名，再公证。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$ROOT/build/pkg"
PKG="$ROOT/build/Backseat.pkg"

bash "$ROOT/scripts/build-app.sh"
bash "$ROOT/scripts/build-driver.sh"

rm -rf "$STAGE"
mkdir -p "$STAGE/root/Applications" "$STAGE/root/Library/Audio/Plug-Ins/HAL" "$STAGE/scripts"
cp -R "$ROOT/build/Backseat.app" "$STAGE/root/Applications/"
cp -R "$ROOT/build/BackseatMic.driver" "$STAGE/root/Library/Audio/Plug-Ins/HAL/"

cat > "$STAGE/scripts/postinstall" <<'POST'
#!/bin/bash
# 让系统的音频服务重新加载驱动（它会自己重新拉起来），新声卡马上出现
/usr/bin/killall coreaudiod 2>/dev/null || true
# 装完直接以当前登录用户身份打开 Backseat，首次启动会弹出设置引导
CONSOLE_USER="$(/usr/bin/stat -f%Su /dev/console)"
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
  /bin/launchctl asuser "$(/usr/bin/id -u "$CONSOLE_USER")" /usr/bin/sudo -u "$CONSOLE_USER" /usr/bin/open /Applications/Backseat.app || true
fi
exit 0
POST
chmod +x "$STAGE/scripts/postinstall"

# 不许安装器「就地升级」：否则它发现磁盘上别处有同一个 App（比如 build/ 里那份），会装到那里去
pkgbuild --analyze --root "$STAGE/root" "$STAGE/components.plist" >/dev/null
python3 - "$STAGE/components.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as f:
    components = plistlib.load(f)
for c in components:
    c["BundleIsRelocatable"] = False
with open(path, "wb") as f:
    plistlib.dump(components, f)
PY

SIGN=()
if [ -n "${BACKSEAT_INSTALLER_ID:-}" ]; then SIGN=(--sign "$BACKSEAT_INSTALLER_ID"); fi
pkgbuild --root "$STAGE/root" --component-plist "$STAGE/components.plist" --scripts "$STAGE/scripts" \
  --identifier dev.backseat.pkg --version 1.0.2 --install-location / ${SIGN[@]+"${SIGN[@]}"} "$PKG" >/dev/null
echo "已生成 $PKG"
