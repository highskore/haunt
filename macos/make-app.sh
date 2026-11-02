#!/bin/bash
# Assembles build/haunt.app from the built binary and Ghostty resources, then signs it.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
ADAPTER="${HAUNT_CLAUDE_ADAPTER:-$ROOT/../haunt-plugins/haunt-claude}"
CODEX_ADAPTER="${HAUNT_CODEX_ADAPTER:-$ROOT/../haunt-plugins/haunt-codex}"
if [ ! -f "$ADAPTER/.claude-plugin/plugin.json" ]; then
  echo "Claude adapter not found at $ADAPTER; clone haunt-claude there or set HAUNT_CLAUDE_ADAPTER" >&2
  exit 1
fi
[ -x "$ROOT/build/macos/haunt" ] || ./build.sh
# The haunt CLI, bundled so the app runs `haunt setup` itself.
(cd "$ROOT" && MACOSX_DEPLOYMENT_TARGET=14.0 cargo build -q --release -p haunt-cli)

APP="$ROOT/build/haunt.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp "$ROOT/build/macos/haunt" "$APP/Contents/MacOS/haunt"
strip -x "$APP/Contents/MacOS/haunt"
cp "$ROOT/target/release/haunt" "$APP/Contents/Helpers/haunt"
cp -R deps/share/ghostty "$APP/Contents/Resources/ghostty"
# libghostty sets TERMINFO to dirname(GHOSTTY_RESOURCES_DIR)/terminfo.
cp -R deps/share/terminfo "$APP/Contents/Resources/terminfo"
cp "$ROOT/design/icon/haunt.icns" "$APP/Contents/Resources/haunt.icns"
cp Resources/openai-mark.png Resources/openai-mark@2x.png "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/adapters/claude"
rsync -a --exclude .git --exclude tests "$ADAPTER/" "$APP/Contents/Resources/adapters/claude/"
if [ -f "$CODEX_ADAPTER/bin/haunt-codex-hook" ]; then
  mkdir -p "$APP/Contents/Resources/adapters/codex"
  rsync -a --exclude .git --exclude tests "$CODEX_ADAPTER/" "$APP/Contents/Resources/adapters/codex/"
else
  echo "Codex adapter not found at $CODEX_ADAPTER; building without it (set HAUNT_CODEX_ADAPTER to bundle it)" >&2
fi

# HAUNT_SIGN_ID or a gitignored .sign-id picks the identity; otherwise ad hoc.
ID="${HAUNT_SIGN_ID:-$(cat "$ROOT/.sign-id" 2>/dev/null || echo -)}"
LOG="$ROOT/build/codesign.log"
echo "== $(date '+%F %T') signing $APP with '$ID'" >>"$LOG"
# Hardened runtime, with the one entitlement wasmtime needs (haunt.entitlements).
sign() { codesign --force --timestamp=none --options runtime --entitlements haunt.entitlements --sign "$1" "$2" 2>>"$LOG"; }
# Nested code is signed before the bundle that seals it, with the same identity.
if ! sign "$ID" "$APP/Contents/Helpers/haunt"; then
  [ "$ID" = - ] && { echo "error: ad hoc signing of the haunt CLI failed; see $LOG" >&2; exit 1; }
  echo "warning: signing the haunt CLI with '$ID' failed ($(tail -1 "$LOG")); signing the whole app ad hoc" >&2
  ID=-
  sign - "$APP/Contents/Helpers/haunt"
fi
if sign "$ID" "$APP"; then
  echo "built $APP (signed: $ID)"
else
  echo "warning: codesign with '$ID' failed ($(tail -1 "$LOG")); signing the whole app ad hoc" >&2
  sign - "$APP/Contents/Helpers/haunt"
  sign - "$APP"
  echo "built $APP (signed: ad hoc)"
fi
