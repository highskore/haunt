#!/bin/bash
# Launches build/haunt-fixtures.app on a mockup fixture, captures its window and runs design/check.
# Usage: macos/fidelity.sh [screen...]   (default: ui-03-icon-only ui-06-grouped-flat ui-10-zen dl-04-palette av-01-narrow-list rv-01-files rv-06-comment rv-09-overview rv-11-inbox nt-07-menu)
# HAUNT_INACTIVE=1 captures the window unfocused; captures then get an -inactive suffix.
set -uo pipefail
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
if [ ! -d "$APP" ] || [ "$FBIN" -nt "$APP/Contents/MacOS/haunt" ] || [ "$ROOT/build/haunt.app" -nt "$APP" ]; then
  rm -rf "$APP"
  cp -R "$ROOT/build/haunt.app" "$APP"
  cp "$FBIN" "$APP/Contents/MacOS/haunt"
  # The log palettes go through the real decision-log plugin, whatever the shipping build bundles.
  rm -rf "$APP/Contents/Resources/plugins"
  ./bundle-plugins.sh "$APP/Contents/Resources/plugins" decision-log >/dev/null || exit 1
  codesign --force --sign - "$APP" >/dev/null 2>&1
fi
status=0
for screen in "${@:-ui-03-icon-only ui-06-grouped-flat ui-10-zen dl-04-palette av-01-narrow-list rv-01-files rv-06-comment rv-09-overview rv-11-inbox nt-07-menu}"; do
  for s in $screen; do
    tag="$s${HAUNT_INACTIVE:+-inactive}"
    # The palette and the menu bar menu are their own windows; the mockup's crop leaves out their 1 pt border.
    width=""
    inset=0
    case "$s" in dl-04-palette) width=400; inset=2 ;; nt-07-menu) width=250; inset=2 ;; esac
    HAUNT_FIXTURE="$s" "$APP/Contents/MacOS/haunt" >"$OUT/$tag-app.log" 2>&1 &
    pid=$!
    win=""
    for _ in $(seq 1 40); do
      sleep 0.25
      win=$(tools/winid-pid "$pid" $width 2>/dev/null) && break
    done
    # Let the surfaces print the fixture and the renderer settle.
    sleep "${HAUNT_SETTLE:-2}"
    if [ -z "$win" ]; then
      echo "$s: no window from pid $pid" >&2
      status=1
    else
      screencapture -x -o -l "${win%% *}" "$OUT/$tag-capture.png"
      if [ "$inset" -gt 0 ]; then
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
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  done
done
exit $status
