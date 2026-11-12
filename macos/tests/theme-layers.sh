#!/bin/bash
# Every first-party theme's layers, loaded through core and drawn at a window's sizes against its own tokens:
# none may be refused or skipped. Needs the fixture build (HAUNT_FIXTURES=1 macos/build.sh); opens no window.
# HAUNT_PLUGINS_DIR is where the haunt-theme-* repos live (default ../haunt-plugins).
set -uo pipefail
cd "$(dirname "$0")/../.."
BIN=build/macos/haunt-fixtures
[ -x "$BIN" ] || { echo "no $BIN: run HAUNT_FIXTURES=1 macos/build.sh" >&2; exit 1; }
DIR="${HAUNT_PLUGINS_DIR:-../haunt-plugins}"
status=0 n=0
for repo in "$DIR"/haunt-theme-*; do
  manifest="$repo/haunt-plugin.toml"
  [ -f "$manifest" ] || continue
  id=$(sed -n '/^\[contributes.theme\]/,/^\[/s/^id = "\(.*\)"$/\1/p' "$manifest" | head -1)
  file=$(sed -n '/^\[contributes.theme\]/,/^\[/s/^file = "\(.*\)"$/\1/p' "$manifest" | head -1)
  [ -n "$id" ] && [ -f "$repo/$file" ] || continue
  grep -q '^\[\[layer\]\]' "$repo/$file" || continue
  n=$((n + 1))
  HAUNT_CHECK_THEME="$id=$repo/$file" "$BIN" || status=1
done
[ "$n" -gt 0 ] || { echo "no theme with layers under $DIR" >&2; exit 1; }
[ "$status" = 0 ] && echo "theme-layers: all passed ($n themes)" || echo "theme-layers: failed"
exit $status
