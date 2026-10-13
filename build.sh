#!/bin/bash
# Builds build/NotchVoice.app. With --install it also replaces ~/Applications/NotchVoice.app and relaunches it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="build/NotchVoice.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/NotchVoice" "$APP/Contents/MacOS/NotchVoice"
cp Info.plist "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --sign - "$APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x NotchVoice || true
  while pgrep -x NotchVoice >/dev/null; do sleep 0.1; done
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/NotchVoice.app"
  ditto "$APP" "$HOME/Applications/NotchVoice.app"
  open "$HOME/Applications/NotchVoice.app"
fi
