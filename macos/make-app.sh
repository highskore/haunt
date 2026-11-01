#!/bin/bash
# Assembles build/haunt.app from the built binary and Ghostty resources, then signs it.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
[ -x "$ROOT/build/macos/haunt" ] || ./build.sh

APP="$ROOT/build/haunt.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp "$ROOT/build/macos/haunt" "$APP/Contents/MacOS/haunt"
strip -x "$APP/Contents/MacOS/haunt"
cp -R deps/share/ghostty "$APP/Contents/Resources/ghostty"
# libghostty sets TERMINFO to dirname(GHOSTTY_RESOURCES_DIR)/terminfo.
cp -R deps/share/terminfo "$APP/Contents/Resources/terminfo"
cp "$ROOT/design/icon/haunt.icns" "$APP/Contents/Resources/haunt.icns"

ID="${HAUNT_SIGN_ID:-Apple Development: rera2k12@gmail.com (MRSS328396)}"
if codesign --force --timestamp=none --sign "$ID" "$APP" 2>"$ROOT/build/codesign.log"; then
  echo "built $APP (signed: $ID)"
else
  echo "codesign with '$ID' failed ($(tail -1 "$ROOT/build/codesign.log")); signing ad hoc" >&2
  codesign --force --sign - "$APP"
  echo "built $APP (signed: ad hoc)"
fi
