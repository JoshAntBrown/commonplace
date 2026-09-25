#!/usr/bin/env bash
# Builds build/Commonplace.app. Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Commonplace"
APP="build/Commonplace.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Commonplace"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp skills/commonplace/SKILL.md "$APP/Contents/Resources/SKILL.md"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
