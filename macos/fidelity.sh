#!/bin/bash
# Launches build/haunt-fixtures.app on a mockup fixture, captures its window and runs design/check.
# Usage: macos/fidelity.sh [screen...]   (default: ui-03-icon-only ui-06-grouped-flat ui-10-zen dl-04-palette av-01-narrow-list rv-01-files rv-06-comment rv-09-overview rv-11-inbox nt-07-menu th-01-glass th-02-sigil th-04-win95)
# The app opens in the background (open -g -n, HAUNT_INACTIVE=1) on a throwaway home and config, so nothing takes
# focus or touches ~/.haunt; captures get an -inactive suffix. Each instance is killed after its capture, or on exit.
set -uo pipefail
export HAUNT_INACTIVE=1
SCRATCH="$(mktemp -d)"
pid=""
cleanup() {
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  [ -d "$SCRATCH" ] && rm -rf "$SCRATCH"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
OUT="$ROOT/design/out"
mkdir -p "$OUT"
# Fixtures exist only in the HAUNT_FIXTURES build: build/haunt.app with that binary swapped in, rebuilt when stale.
APP="$ROOT/build/haunt-fixtures.app"
FBIN="$ROOT/build/macos/haunt-fixtures"
[ -d "$ROOT/build/haunt.app" ] || { echo "no build/haunt.app: run macos/make-app.sh" >&2; exit 1; }
if [ ! -x "$FBIN" ] || [ -n "$(find Sources Vendor deps/lib -newer "$FBIN" -print -quit)" ]; then
  HAUNT_FIXTURES=1 ./build.sh >/dev/null || exit 1
fi
PLUGINS="${HAUNT_PLUGINS_DIR:-$ROOT/../haunt-plugins}"
# The bundled plugins' files by content, found through any symlinked plugin folder.
plugins_sum=$(find -H "$PLUGINS/haunt-decision-log" "$PLUGINS/haunt-theme-glass" "$PLUGINS/haunt-theme-sigil" "$PLUGINS/haunt-theme-win95" \
  -type f -not -path '*/target/*' -not -path '*/.git/*' -print0 2>/dev/null | sort -z | xargs -0 shasum | shasum | cut -d' ' -f1)
if [ ! -d "$APP" ] || [ "$FBIN" -nt "$APP/Contents/MacOS/haunt" ] || [ "$ROOT/build/haunt.app" -nt "$APP" ] ||
  [ "$plugins_sum" != "$(cat "$ROOT/build/haunt-fixtures.plugins" 2>/dev/null)" ]; then
  rm -rf "$APP"
  cp -R "$ROOT/build/haunt.app" "$APP"
  cp "$FBIN" "$APP/Contents/MacOS/haunt"
  # The log palettes go through the real decision-log plugin, and th- screens through their theme plugin,
  # whatever the shipping build bundles.
  rm -rf "$APP/Contents/Resources/plugins"
  ./bundle-plugins.sh "$APP/Contents/Resources/plugins" decision-log,theme-glass,theme-sigil,theme-win95 >/dev/null || exit 1
  codesign --force --sign - "$APP" >/dev/null 2>&1
  echo "$plugins_sum" >"$ROOT/build/haunt-fixtures.plugins"
fi
status=0
for screen in "${@:-ui-03-icon-only ui-06-grouped-flat ui-10-zen dl-04-palette av-01-narrow-list rv-01-files rv-06-comment rv-09-overview rv-11-inbox nt-07-menu th-01-glass th-02-sigil th-04-win95}"; do
  for s in $screen; do
    tag="$s${HAUNT_INACTIVE:+-inactive}"
    # The palette and the menu bar menu are their own windows; the mockup's crop leaves out their 1 pt border.
    width=""
    inset=0
    case "$s" in dl-04-palette) width=400; inset=2 ;; nt-07-menu) width=250; inset=2 ;; th-02-sigil) width=900; inset=2 ;; th-04-win95) width=900 ;; esac
    # Glass shows the card's wallpaper, blurred, instead of the desktop.
    backdrop=""
    [ -f "$ROOT/design/reference/$s-backdrop.png" ] && backdrop="$ROOT/design/reference/$s-backdrop.png"
    mkdir -p "$SCRATCH/$s/home" "$SCRATCH/$s/config"
    open -g -n --env HAUNT_INACTIVE=1 --env HAUNT_HOME="$SCRATCH/$s/home" --env HAUNT_CONFIG_DIR="$SCRATCH/$s/config" \
      --env HAUNT_FIXTURE="$s" --env HAUNT_BACKDROP="$backdrop" --stdout "$OUT/$tag-app.log" --stderr "$OUT/$tag-app.log" "$APP"
    pid=""
    win=""
    for _ in $(seq 1 40); do
      sleep 0.25
      [ -n "$pid" ] || pid=$(pgrep -n -f "^$APP/Contents/MacOS/haunt" || true)
      [ -n "$pid" ] && win=$(tools/winid-pid "$pid" $width 2>/dev/null) && break
    done
    # Let the surfaces print the fixture and the renderer settle.
    sleep "${HAUNT_SETTLE:-2}"
    if [ -z "$win" ]; then
      echo "$s: no window from pid $pid" >&2
      status=1
    else
      screencapture -x -o -l "${win%% *}" "$OUT/$tag-capture.png"
      if [ -n "$width" ]; then
        # screencapture -l on a child window sometimes returns the whole window group; then the panel is
        # cut out of it at its offset from the main window.
        main=$(tools/winid-pid "$pid" 900)
        uv run --quiet --no-project --with pillow python -I -c '
import sys
from PIL import Image
p, n = sys.argv[1], int(sys.argv[2])
_, pw, ph, px, py = map(int, sys.argv[3].split())
_, mw, mh, mx, my = map(int, sys.argv[4].split())
im = Image.open(p)
x, y = (0, 0) if im.width == pw * 2 else ((px - mx) * 2, (py - my) * 2)
im.crop((x + n, y + n, x + pw * 2 - n, y + ph * 2 - n)).save(p, icc_profile=im.info.get("icc_profile"))
' "$OUT/$tag-capture.png" "$inset" "$win" "$main"
      fi
      "$ROOT/design/check" "$OUT/$tag-capture.png" "$s" --out "$OUT${HAUNT_INACTIVE:+/inactive}" || status=1
    fi
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null
      for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    fi
    pid=""
  done
done
exit $status
