#!/bin/zsh
# Builds DockHack.app and installs it to ~/Applications. Usage: ./build.sh [--no-install]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/DockHack"

APP=build/DockHack.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/DockHack"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier dev.local.dockhack "$APP"
echo "Built $APP"

if [[ "${1:-}" != "--no-install" ]]; then
  pkill -x DockHack 2>/dev/null && sleep 0.5 || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/DockHack.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/DockHack.app
  echo "Installed and launched ~/Applications/DockHack.app"
fi
