#!/bin/bash
# Assembles build/haunt.app from the built binary and Ghostty resources, then signs it.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
ADAPTER="${HAUNT_CLAUDE_ADAPTER:-$ROOT/../haunt-plugins/haunt-claude}"
if [ ! -f "$ADAPTER/.claude-plugin/plugin.json" ]; then
  echo "Claude adapter not found at $ADAPTER; clone haunt-claude there or set HAUNT_CLAUDE_ADAPTER" >&2
  exit 1
fi
[ -x "$ROOT/build/macos/haunt" ] || ./build.sh

# Adapters are bundled at the commit adapters.lock pins, via git archive, so dirty or unpushed files
# never reach the signed bundle. HAUNT_ADAPTER_UNPINNED=1 copies the working tree instead.
# adapter_rev <name> <checkout>: the pinned rev, checked before anything is built; "" when unpinned.
adapter_rev() {
  local name="$1" src="$2" rev
  [ "${HAUNT_ADAPTER_UNPINNED:-}" = 1 ] && return
  rev=$(awk -v n="$name" '$1 == n { print $3 }' adapters.lock)
  if [ -z "$rev" ]; then
    echo "no $name rev in macos/adapters.lock" >&2; return 1
  fi
  if [ -n "$(git -C "$src" status --porcelain)" ]; then
    echo "$name adapter at $src has uncommitted changes; commit them or set HAUNT_ADAPTER_UNPINNED=1" >&2; return 1
  fi
  if [ "$(git -C "$src" rev-parse HEAD)" != "$rev" ]; then
    echo "$name adapter at $src is at $(git -C "$src" rev-parse --short HEAD), adapters.lock pins ${rev:0:7}; check out the pin, bump it, or set HAUNT_ADAPTER_UNPINNED=1" >&2; return 1
  fi
  echo "$rev"
}

# bundle_adapter <name> <checkout> <rev> <dest>
bundle_adapter() {
  local name="$1" src="$2" rev="$3" dest="$4"
  mkdir -p "$dest"
  if [ -z "$rev" ]; then
    echo "warning: bundling the $name adapter working tree unpinned" >&2
    rsync -a --exclude .git --exclude tests "$src/" "$dest/"
  else
    git -C "$src" archive "$rev" | tar -x -C "$dest" --exclude tests
  fi
}
CLAUDE_REV=$(adapter_rev claude "$ADAPTER") || exit 1

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
cp Resources/codex-logo.png "$APP/Contents/Resources/codex-logo.png"
bundle_adapter claude "$ADAPTER" "$CLAUDE_REV" "$APP/Contents/Resources/adapters/claude"

# HAUNT_SIGN_ID or a gitignored .sign-id picks the identity; otherwise ad hoc.
ID="${HAUNT_SIGN_ID:-$(cat "$ROOT/.sign-id" 2>/dev/null || echo -)}"
if codesign --force --timestamp=none --sign "$ID" "$APP" 2>"$ROOT/build/codesign.log"; then
  echo "built $APP (signed: $ID)"
else
  echo "codesign with '$ID' failed ($(tail -1 "$ROOT/build/codesign.log")); signing ad hoc" >&2
  codesign --force --sign - "$APP"
  echo "built $APP (signed: ad hoc)"
fi
