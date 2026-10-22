#!/bin/zsh
# Builds build/Ejectable.app (ad-hoc signed, icon, version) and build/ejectctl from `swift build -c release`.
#
#   ./build.sh            build only
#   ./build.sh run        build, quit any running Ejectable, launch build/Ejectable.app
#   ./build.sh install    build, quit any running Ejectable, copy to ~/Applications/Ejectable.app and launch it there
#                         (Launch at Login needs the installed copy)
#   ./build.sh release    build, then print bundle / binary sizes and the idle RSS + CPU of a 3 s test launch
#   ./build.sh help       this text
#
#   ARCHS="arm64 x86_64"  architectures to build (default: both, a universal binary); ARCHS=arm64 is faster.
#
# Version: CFBundleShortVersionString in Resources/Info.plist. Build number: git commit count (0 before the first one).
set -euo pipefail
cd "$(dirname "$0")"
NAME=Ejectable
BUNDLE_ID=com.benrusnac.ejectable
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 0)
ARCHS=(${=ARCHS:-arm64 x86_64})
MODE=${1:-}
case "$MODE" in
  ""|run|install|release) ;;
  help|-h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
  *) echo "usage: $0 [run|install|release|help]" >&2; exit 64;;
esac

# -no_exported_symbols: an executable exports nothing anyone links against (EjectKit is linked in statically); drops
# the export trie (~110 KB of __LINKEDIT). Debug entry points (--eject, --debug-hooks, SIGUSR1) are #if DEBUG: a
# release build does not contain them. One build per architecture, joined with lipo.
FLAGS=(-c release -Xlinker -no_exported_symbols)
APP_BINS=() CTL_BINS=()
for arch in $ARCHS; do
  swift build $FLAGS --arch $arch 2>&1 | tail -3
  BIN_DIR=$(swift build $FLAGS --arch $arch --show-bin-path)
  APP_BINS+=("$BIN_DIR/$NAME") CTL_BINS+=("$BIN_DIR/ejectctl")
done
mkdir -p build
lipo -create -output build/.$NAME.universal $APP_BINS
lipo -create -output build/.ejectctl.universal $CTL_BINS

APP=build/$NAME.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
strip -x -o "$APP/Contents/MacOS/$NAME" build/.$NAME.universal      # drop local symbols (~170 KB per architecture)
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # regenerate: swift Tools/make-icon.swift
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

strip -x -o build/ejectctl build/.ejectctl.universal
codesign --force --sign - --identifier "$BUNDLE_ID.ejectctl" build/ejectctl
rm -f build/.$NAME.universal build/.ejectctl.universal

echo "built $APP $VERSION ($BUILD_NUMBER) [$ARCHS], $(stat -f %z "$APP/Contents/MacOS/$NAME") bytes binary;" \
     "build/ejectctl $(stat -f %z build/ejectctl) bytes"

# SIGTERM to Ejectable itself (it keeps no unsaved state), then wait until it is gone.
quit_running() {
  pkill -x "$NAME" 2>/dev/null || return 0
  for _ in {1..30}; do pgrep -x "$NAME" >/dev/null || return 0; sleep 0.1; done
}

case "$MODE" in
  run)
    quit_running
    open "$APP"
    ;;
  install)
    [[ -n "$HOME" ]] || { echo "HOME is not set" >&2; exit 1; }
    DEST="$HOME/Applications/$NAME.app"
    mkdir -p "$HOME/Applications"
    quit_running
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
    open "$DEST"
    echo "installed $DEST and launched it"
    ;;
  release)
    echo "bundle $(du -sk "$APP" | cut -f1) KB (icon $(( $(stat -f %z "$APP/Contents/Resources/AppIcon.icns") / 1024 )) KB)"
    if pgrep -x "$NAME" >/dev/null; then
      echo "idle RSS: not measured ($NAME is running; quit it first)"
    else
      "$APP/Contents/MacOS/$NAME" >/dev/null 2>&1 &
      PID=$!
      sleep 3
      RSS_KB=$(ps -o rss= -p $PID | tr -d ' ')
      CPU=$(ps -o %cpu= -p $PID | tr -d ' ')
      kill $PID 2>/dev/null || true
      wait $PID 2>/dev/null || true
      echo "idle after 3 s: RSS $(( RSS_KB / 1024 )) MB ($RSS_KB KB), CPU $CPU%"
    fi
    ;;
esac
