#!/bin/bash
# Launches build/haunt.app on a mockup fixture, captures its window and runs design/check.
# Usage: macos/fidelity.sh [screen...]   (default: ui-03-icon-only ui-06-grouped-flat)
# HAUNT_INACTIVE=1 captures the window unfocused; captures then get an -inactive suffix.
set -uo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
OUT="$ROOT/design/out"
mkdir -p "$OUT"
status=0
for screen in "${@:-ui-03-icon-only ui-06-grouped-flat}"; do
  for s in $screen; do
    tag="$s${HAUNT_INACTIVE:+-inactive}"
    HAUNT_FIXTURE="$s" "$ROOT/build/haunt.app/Contents/MacOS/haunt" >"$OUT/$tag-app.log" 2>&1 &
    pid=$!
    win=""
    for _ in $(seq 1 40); do
      sleep 0.25
      win=$(tools/winid-pid "$pid" 2>/dev/null) && break
    done
    # Let the surfaces print the fixture and the renderer settle.
    sleep "${HAUNT_SETTLE:-2}"
    if [ -z "$win" ]; then
      echo "$s: no window from pid $pid" >&2
      status=1
    else
      screencapture -x -o -l "${win%% *}" "$OUT/$tag-capture.png"
      "$ROOT/design/check" "$OUT/$tag-capture.png" "$s" --out "$OUT${HAUNT_INACTIVE:+/inactive}" || status=1
    fi
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  done
done
exit $status
