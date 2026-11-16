#!/bin/bash
# 自己用 Xcode 编译手机 / 手表 App 前运行一次：把签名团队写进 apps/Config.local.xcconfig，并生成 Xcode 工程。
# token、Claude Code hooks 由 Mac 端首次启动时自动配置；Mac 地址在 App 里配对时获取。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 已有配置时沿用其中的团队；否则从证书 OU 字段取（证书括号里的是个人 ID）
TEAM=$(sed -nE 's/^DEVELOPMENT_TEAM = ([A-Z0-9]{10})$/\1/p' "$ROOT/apps/Config.local.xcconfig" 2>/dev/null || true)
[ -z "$TEAM" ] && TEAM=$(security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -nE 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/p' | head -1)
# App 的 Bundle ID 默认带上团队 ID（保证每个人的都不重复）；已有配置里自己改过的话沿用
BUNDLE=$(sed -nE 's/^BACKSEAT_BUNDLE_ID = (.+)$/\1/p' "$ROOT/apps/Config.local.xcconfig" 2>/dev/null || true)
{
  echo "DEVELOPMENT_TEAM = ${BACKSEAT_TEAM:-$TEAM}"
  echo "BACKSEAT_BUNDLE_ID = ${BUNDLE:-dev.backseat.\$(DEVELOPMENT_TEAM).phone}"
} > "$ROOT/apps/Config.local.xcconfig"
echo "App 签名团队：${BACKSEAT_TEAM:-${TEAM:-未找到，请在 Xcode 里手动选择}}"

if ! command -v xcodegen >/dev/null; then
  echo "需要 XcodeGen 来生成工程：brew install xcodegen，装好后重新运行本脚本"
  exit 1
fi
(cd "$ROOT/apps" && xcodegen generate -q)
echo "已生成 apps/Backseat.xcodeproj"
