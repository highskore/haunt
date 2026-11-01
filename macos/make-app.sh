#!/bin/bash
# Assembles build/haunt.app from the built binary, Ghostty resources and first-party plugins.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
[ -x "$ROOT/build/macos/Haunt" ] || ./build.sh

APP="$ROOT/build/haunt.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/plugins"
cp Info.plist "$APP/Contents/Info.plist"
cp "$ROOT/build/macos/Haunt" "$APP/Contents/MacOS/Haunt"
strip -x "$APP/Contents/MacOS/Haunt"
cp -R deps/share/ghostty "$APP/Contents/Resources/ghostty"
# libghostty sets TERMINFO to dirname(GHOSTTY_RESOURCES_DIR)/terminfo.
cp -R deps/share/terminfo "$APP/Contents/Resources/terminfo"
cp "$ROOT/examples/hello/target/wasm32-wasip2/release/hello_plugin.wasm" "$APP/Contents/Resources/plugins/hello.wasm"
[ -f "$ROOT/design/icon/haunt.icns" ] && cp "$ROOT/design/icon/haunt.icns" "$APP/Contents/Resources/haunt.icns"

# Spike: ad hoc. Phase 0 item 4 wants a self-signed "haunt Dev" cert, which needs a keychain change.
ID=$(security find-identity -p codesigning 2>/dev/null | awk '/"haunt Dev"/ { print $2; exit }' || true)
codesign --force --sign "${ID:--}" "$APP"
echo "built $APP ($( [ -n "$ID" ] && echo 'haunt Dev' || echo 'ad hoc'))"
