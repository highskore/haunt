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
# Always rebuilt, as the real-core shipping binary, so no stale or fixture build gets signed.
HAUNT_CORE=real HAUNT_FIXTURES=0 ./build.sh
# The haunt CLI, bundled so the app runs `haunt setup` itself.
(cd "$ROOT" && MACOSX_DEPLOYMENT_TARGET=14.0 cargo build -q --release -p haunt-cli)

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
CODEX_ADAPTER_FOUND="" CODEX_REV=""
if [ -f "$CODEX_ADAPTER/bin/haunt-codex-hook" ]; then
  CODEX_ADAPTER_FOUND=1
  CODEX_REV=$(adapter_rev codex "$CODEX_ADAPTER") || exit 1
fi

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
bundle_adapter claude "$ADAPTER" "$CLAUDE_REV" "$APP/Contents/Resources/adapters/claude"
if [ -n "$CODEX_ADAPTER_FOUND" ]; then
  bundle_adapter codex "$CODEX_ADAPTER" "$CODEX_REV" "$APP/Contents/Resources/adapters/codex"
else
  echo "Codex adapter not found at $CODEX_ADAPTER; building without it (set HAUNT_CODEX_ADAPTER to bundle it)" >&2
fi
# First-party plugins, installed on launch without a prompt (they are sealed by the signature below).
for repo in ${HAUNT_FIRST_PARTY_PLUGINS:-$ROOT/../haunt-plugins/haunt-decision-log $ROOT/../haunt-plugins/haunt-allowlist}; do
  if [ ! -f "$repo/haunt-plugin.toml" ]; then
    echo "plugin not found at $repo; building without it" >&2
    continue
  fi
  (cd "$repo" && cargo build -q --release --target wasm32-wasip2)
  id=$(sed -n 's/^id = "\(.*\)"$/\1/p' "$repo/haunt-plugin.toml" | head -1)
  entry=$(sed -n 's/^entry = "\(.*\)"$/\1/p' "$repo/haunt-plugin.toml" | head -1)
  mkdir -p "$APP/Contents/Resources/plugins/$id"
  sed 's/^entry = .*/entry = "plugin.wasm"/' "$repo/haunt-plugin.toml" >"$APP/Contents/Resources/plugins/$id/haunt-plugin.toml"
  cp "$repo/$entry" "$APP/Contents/Resources/plugins/$id/plugin.wasm"
done

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
