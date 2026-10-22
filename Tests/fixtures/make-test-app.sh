#!/bin/bash
# Builds .build/fixtures/DUTestHolder.app (GUI test app for TerminatorTests) when missing or out of date.
# Prints the bundle path.
#   make-test-app.sh --fake-editor   also builds .build/fixtures/DUFakeEditor.app: the same binary with a FAKE
#                                    Premiere-like bundle id (com.adobe.PremierePro.dutest) for the S10 toast test.
#                                    It is not an NLE; it only lets the test see a running "editor" by bundle id.
#   make-test-app.sh --background-only
#                                    also builds .build/fixtures/DUTestExtension.app: the same binary, LSBackgroundOnly,
#                                    so LaunchServices gives it activation policy .prohibited and Ejectable classifies it
#                                    .appExtension (like AirDrop.appex). Bundle id com.benrusnac.ejectable.testextension.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
SRC="$ROOT/Tests/fixtures/TestHolderApp/main.swift"
APP="$ROOT/.build/fixtures/DUTestHolder.app"
BIN="$APP/Contents/MacOS/DUTestHolder"
if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ] || [ "$0" -nt "$BIN" ]; then
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS"
  swiftc -O -swift-version 6 -o "$BIN" "$SRC" >&2
  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.benrusnac.ejectable.testholder</string>
  <key>CFBundleName</key><string>DUTestHolder</string>
  <key>CFBundleExecutable</key><string>DUTestHolder</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
  codesign --force --sign - "$APP" >&2
fi
if [ "${1:-}" = --background-only ]; then
  EXT="$ROOT/.build/fixtures/DUTestExtension.app"
  if [ ! -x "$EXT/Contents/MacOS/DUTestExtension" ] || [ "$BIN" -nt "$EXT/Contents/MacOS/DUTestExtension" ] || [ "$0" -nt "$EXT/Contents/MacOS/DUTestExtension" ]; then
    rm -rf "$EXT"
    mkdir -p "$EXT/Contents/MacOS"
    cp "$BIN" "$EXT/Contents/MacOS/DUTestExtension"
    sed -e 's/com.benrusnac.ejectable.testholder/com.benrusnac.ejectable.testextension/' -e 's/DUTestHolder/DUTestExtension/g' \
      -e 's#<key>LSUIElement</key><true/>#<key>LSBackgroundOnly</key><true/>#' \
      "$APP/Contents/Info.plist" > "$EXT/Contents/Info.plist"
    codesign --force --sign - "$EXT" >&2
  fi
  echo "$EXT"
  exit 0
fi
if [ "${1:-}" = --fake-editor ]; then
  FAKE="$ROOT/.build/fixtures/DUFakeEditor.app"
  if [ ! -x "$FAKE/Contents/MacOS/DUFakeEditor" ] || [ "$BIN" -nt "$FAKE/Contents/MacOS/DUFakeEditor" ] || [ "$0" -nt "$FAKE/Contents/MacOS/DUFakeEditor" ]; then
    rm -rf "$FAKE"
    mkdir -p "$FAKE/Contents/MacOS"
    cp "$BIN" "$FAKE/Contents/MacOS/DUFakeEditor"
    sed -e 's/com.benrusnac.ejectable.testholder/com.adobe.PremierePro.dutest/' -e 's/DUTestHolder/DUFakeEditor/g' \
      "$APP/Contents/Info.plist" > "$FAKE/Contents/Info.plist"
    codesign --force --sign - "$FAKE" >&2
  fi
  echo "$FAKE"
  exit 0
fi
echo "$APP"
