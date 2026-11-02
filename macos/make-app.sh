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
cp Resources/codex-logo.png "$APP/Contents/Resources/codex-logo.png"
mkdir -p "$APP/Contents/Resources/adapters/claude"
rsync -a --exclude .git --exclude tests "$ADAPTER/" "$APP/Contents/Resources/adapters/claude/"
if [ -f "$CODEX_ADAPTER/bin/haunt-codex-hook" ]; then
  mkdir -p "$APP/Contents/Resources/adapters/codex"
  rsync -a --exclude .git --exclude tests "$CODEX_ADAPTER/" "$APP/Contents/Resources/adapters/codex/"
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
# Nested code is signed before the bundle that seals it.
codesign --force --timestamp=none --sign "$ID" "$APP/Contents/Helpers/haunt" 2>"$ROOT/build/codesign.log" \
  || codesign --force --sign - "$APP/Contents/Helpers/haunt"
if codesign --force --timestamp=none --sign "$ID" "$APP" 2>"$ROOT/build/codesign.log"; then
  echo "built $APP (signed: $ID)"
else
  echo "codesign with '$ID' failed ($(tail -1 "$ROOT/build/codesign.log")); signing ad hoc" >&2
  codesign --force --sign - "$APP"
  echo "built $APP (signed: ad hoc)"
fi
