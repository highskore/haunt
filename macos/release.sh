#!/bin/bash
# Builds a release locally: haunt.app with every pinned plugin, its signature checked, zipped to
# build/haunt-<version>-arm64.zip with a .sha256, and build/RELEASE_NOTES.md. Publishes nothing.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
APP="$ROOT/build/haunt.app"
fail() { echo "release: $*" >&2; exit 1; }

[ -z "$(git -C "$ROOT" status --porcelain)" ] || fail "uncommitted changes; a release is built from a commit"
COMMIT=$(git -C "$ROOT" rev-parse HEAD)
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
ZIP="haunt-$VERSION-arm64.zip"

./make-app.sh --plugins all

# Signed as make-app signs it: the same identity on the CLI and the app, hardened runtime, wasmtime's entitlement.
codesign --verify --deep --strict "$APP" || fail "the bundle's signature doesn't verify"
# Each reads codesign's whole output: a reader that stops early fails the pipe under pipefail.
authority() { codesign -dvv "$1" 2>&1 | awk -F= '/^Authority=/ && !n++ { print $2 }'; }
flags() { codesign -dv "$1" 2>&1 | sed -n 's/^CodeDirectory.*flags=\(0x[0-9a-f]*\)(\(.*\)).*/\2/p'; }
WANT_ID="${HAUNT_SIGN_ID:-$(cat "$ROOT/.sign-id" 2>/dev/null || echo -)}"
ID=$(authority "$APP")
[ "$ID" = "$(authority "$APP/Contents/Helpers/haunt")" ] || fail "the CLI and the app are signed by different identities"
# A name must match exactly; a certificate hash can only be checked as "not ad hoc".
if [ "$WANT_ID" != - ] && { [ -z "$ID" ] || { [[ ! "$WANT_ID" =~ ^[0-9A-Fa-f]{40}$ ]] && [ "$ID" != "$WANT_ID" ]; }; }; then
  fail "expected a signature by '$WANT_ID', got '${ID:-ad hoc}' (make-app fell back; see build/codesign.log)"
fi
for f in "$APP" "$APP/Contents/Helpers/haunt"; do
  [[ "$(flags "$f")" == *runtime* ]] || fail "$f is signed without the hardened runtime"
done
[[ "$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)" == *allow-unsigned-executable-memory* ]] \
  || fail "the app is missing the entitlement wasmtime needs"
for f in "$APP/Contents/MacOS/haunt" "$APP/Contents/Helpers/haunt"; do
  [ "$(lipo -archs "$f")" = arm64 ] || fail "$f is $(lipo -archs "$f"), not arm64 only"
done

rm -f "$ROOT/build/$ZIP" "$ROOT/build/$ZIP.sha256"
ditto -c -k --keepParent "$APP" "$ROOT/build/$ZIP"
(cd "$ROOT/build" && shasum -a 256 "$ZIP" >"$ZIP.sha256")
SHA=$(cut -d' ' -f1 "$ROOT/build/$ZIP.sha256")

# One "- name version (repo@rev): description" line per pinned plugin, split into code plugins and themes.
PLUGINS="" THEMES=""
while read -r name repo rev; do
  case "$name" in ''|'#'*) continue ;; esac
  manifest=$(git -C "${HAUNT_PLUGINS_DIR:-$ROOT/../haunt-plugins}/haunt-$name" show "$rev:haunt-plugin.toml")
  field() { sed -n "s/^$1 = \"\(.*\)\"$/\1/p" <<<"$manifest" | head -1; }
  [ -d "$APP/Contents/Resources/plugins/$(field id)" ] || fail "$name is pinned but not in the bundle"
  line="- **$(field name)** $(field version) ($(basename "$repo" .git)@${rev:0:7}): $(field description)"
  if grep -q '^theme = true$' <<<"$manifest"; then THEMES+="$line"$'\n'; else PLUGINS+="$line"$'\n'; fi
done <plugins.lock

ADAPTERS=""
while read -r name repo rev; do
  case "$name" in ''|'#'*) continue ;; esac
  [ -d "$APP/Contents/Resources/adapters/$name" ] && ADAPTERS+="- The $name adapter ($(basename "$repo" .git)@${rev:0:7}), which sends the agent's hook events to Haunt."$'\n'
done <adapters.lock

# Never the identity's name: it carries the developer's email.
if [ -z "$ID" ]; then SIGNED="Ad-hoc signed"; else SIGNED="Signed with a developer certificate"; fi
GATEKEEPER=""
if xcrun stapler validate "$APP" >/dev/null 2>&1; then
  SIGNED+=" (notarized)"
else
  SIGNED+=" (not notarized)"
  GATEKEEPER=$'\nThis build is not notarized, so macOS blocks the first launch. Open it once, then go to System Settings ▸ Privacy & Security and click Open Anyway next to haunt. On macOS 15, Control-click ▸ Open no longer skips this step.'
fi

notes=$(<release-notes.md)
notes=${notes//"{{VERSION}}"/$VERSION}
notes=${notes//"{{COMMIT}}"/${COMMIT:0:12}}
notes=${notes//"{{ADAPTERS}}"/${ADAPTERS%$'\n'}}
PLUGINS=${PLUGINS%$'\n'} THEMES=${THEMES%$'\n'}
notes=${notes//"{{PLUGINS}}"/${PLUGINS:-None.}}
notes=${notes//"{{THEMES}}"/${THEMES:-None.}}
notes=${notes//"{{ZIP}}"/$ZIP}
notes=${notes//"{{SHA256}}"/$SHA}
notes=${notes//"{{SIGNED}}"/$SIGNED}
notes=${notes//"{{GATEKEEPER}}"/$GATEKEEPER}
printf '%s\n' "$notes" >"$ROOT/build/RELEASE_NOTES.md"

echo "release: build/$ZIP ($SHA), build/RELEASE_NOTES.md"
