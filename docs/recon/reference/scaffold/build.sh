#!/bin/zsh
# One-command build: swift build -> assemble .app -> ad-hoc codesign.  Usage: ./build.sh [run]
set -euo pipefail
cd "$(dirname "$0")"
NAME=Hello
swift build -c release --arch arm64 2>&1 | tail -3
BIN=$(swift build -c release --arch arm64 --show-bin-path)/$NAME
APP=build/$NAME.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier com.benrusnac.hello "$APP"
echo "built $APP ($(du -sk "$APP/Contents/MacOS/$NAME" | cut -f1) KB binary)"
[[ "${1:-}" == run ]] && { pkill -x $NAME 2>/dev/null || true; open "$APP"; }
