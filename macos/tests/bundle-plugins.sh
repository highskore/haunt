#!/bin/bash
# make-app's plugin bundling: none by default, exactly what --plugins names, and unknown names refused.
set -euo pipefail
cd "$(dirname "$0")/../.."
DIR="${HAUNT_PLUGINS_DIR:-$(pwd)/../haunt-plugins}"
if [ ! -f "$DIR/haunt-tabs-plus/haunt-plugin.toml" ]; then
  echo "bundle-plugins: skipped, haunt-tabs-plus not found in $DIR"
  exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL $*"; exit 1; }

macos/bundle-plugins.sh "$T/default" "" >/dev/null
[ ! -e "$T/default" ] || [ -z "$(ls -A "$T/default")" ] || fail "the default bundle has plugins: $(ls "$T/default")"
HAUNT_PLUGINS_DIR="$DIR" macos/bundle-plugins.sh "$T/none" none >/dev/null
[ ! -e "$T/none" ] || fail "none bundled something"

HAUNT_PLUGINS_DIR="$DIR" macos/bundle-plugins.sh "$T/tabs" tabs-plus >/dev/null
[ "$(ls "$T/tabs")" = dev.haunt.tabs-plus ] || fail "--plugins tabs-plus gave: $(ls "$T/tabs")"
grep -qx 'entry = "plugin.wasm"' "$T/tabs/dev.haunt.tabs-plus/haunt-plugin.toml" || fail "entry not rewritten"
[ -s "$T/tabs/dev.haunt.tabs-plus/plugin.wasm" ] || fail "no wasm"

set +e
HAUNT_PLUGINS_DIR="$DIR" macos/bundle-plugins.sh "$T/bad" tabs-plus,tabs 2>"$T/err"; code=$?
set -e
[ "$code" = 2 ] && grep -q "unknown plugin 'tabs'" "$T/err" && [ ! -e "$T/bad" ] || fail "unknown name: exit $code, $(cat "$T/err")"
# The names offered are the plugin repos, not the adapters or the template.
grep -q "tabs-plus, " "$T/err" && ! sed "s#$DIR##g" "$T/err" | grep -qE "claude|codex|template" || fail "offered: $(cat "$T/err")"
set +e
HAUNT_PLUGINS_DIR="$T/nowhere" macos/bundle-plugins.sh --check /dev/null tabs-plus 2>"$T/err"; code=$?
set -e
[ "$code" = 2 ] && grep -q "no plugin repo at $T/nowhere/haunt-tabs-plus" "$T/err" || fail "missing repo: exit $code"
macos/bundle-plugins.sh --check /dev/null "" || fail "--check of nothing"

# A name is never a glob, and a repo is built once however often it is named.
set +e
HAUNT_PLUGINS_DIR="$DIR" macos/bundle-plugins.sh --check /dev/null '*' 2>"$T/err"; code=$?
set -e
[ "$code" = 2 ] && grep -q "unknown plugin '\*'" "$T/err" || fail "glob name: exit $code, $(cat "$T/err")"
n=$(HAUNT_PLUGINS_DIR="$DIR" HAUNT_FIRST_PARTY_PLUGINS="$DIR/haunt-tabs-plus" macos/bundle-plugins.sh "$T/twice" "tabs-plus, tabs-plus" | grep -c "bundled plugin")
[ "$n" = 1 ] || fail "tabs-plus built $n times"

# HAUNT_FIRST_PARTY_PLUGINS repos get the same checks: a real id, and an entry inside the repo.
mkdir -p "$T/fake" "$T/placeholder"
sed 's/^entry = .*/entry = "..\/escape.wasm"/' "$DIR/haunt-tabs-plus/haunt-plugin.toml" >"$T/fake/haunt-plugin.toml"
sed 's/^id = .*/id = "{{id}}"/' "$DIR/haunt-tabs-plus/haunt-plugin.toml" >"$T/placeholder/haunt-plugin.toml"
set +e
HAUNT_FIRST_PARTY_PLUGINS="$T/fake" macos/bundle-plugins.sh "$T/escape" "" 2>"$T/err"; code=$?
set -e
[ "$code" = 1 ] && grep -q "must be a relative path inside the repo" "$T/err" && [ ! -e "$T/escape" ] || fail "entry outside: exit $code, $(cat "$T/err")"
HAUNT_FIRST_PARTY_PLUGINS="$T/placeholder" macos/bundle-plugins.sh "$T/ph" "" 2>"$T/err"
[ ! -e "$T/ph" ] && grep -q "no plugin with a real id" "$T/err" || fail "placeholder id bundled"
# A data-only theme plugin: no build, its manifest as it is and only the files it names; `all` picks it up.
P="$T/plugins/haunt-theme-glass"
mkdir -p "$P/fonts" "$T/outside"
cat >"$P/haunt-plugin.toml" <<'EOF'
[plugin]
id = "dev.haunt.theme-glass"
name = "Glass"
version = "0.1.0"
api = "0.4"
[capabilities]
theme = true
[contributes.theme]
id = "glass"
file = "theme.toml"
fonts = ["fonts/A.ttf"]
licenses = ["OFL.txt"]
EOF
echo 'name = "Glass"' >"$P/theme.toml"
echo font >"$P/fonts/A.ttf"
echo licence >"$P/OFL.txt"
echo readme >"$P/README.md"
HAUNT_PLUGINS_DIR="$T/plugins" macos/bundle-plugins.sh "$T/theme" all >/dev/null
G="$T/theme/dev.haunt.theme-glass"
[ "$(cd "$G" && find . -type f | sort | tr '\n' ' ')" = "./OFL.txt ./fonts/A.ttf ./haunt-plugin.toml ./theme.toml " ] ||
  fail "theme bundle: $(cd "$G" && find . -type f)"
cmp -s "$P/haunt-plugin.toml" "$G/haunt-plugin.toml" || fail "theme manifest changed"
rm -r "$P/fonts" && ln -s "$T/outside" "$P/fonts" && echo font >"$T/outside/A.ttf"
set +e
HAUNT_PLUGINS_DIR="$T/plugins" macos/bundle-plugins.sh "$T/linked" theme-glass 2>"$T/err"; code=$?
set -e
[ "$code" = 1 ] && grep -q "fonts/A.ttf is not a regular file inside it" "$T/err" || fail "symlinked font dir: exit $code, $(cat "$T/err")"

# Every repo is checked before any is built, and the id is [plugin]'s, read as TOML.
mkdir -p "$T/badid"
printf '[plugin]\nid = "Dev.Haunt.X"\nname = "X"\nversion = "0.1.0"\napi = "0.4"\nentry = "x.wasm"\n[contributes.theme]\nid = "dev.haunt.x"\n' >"$T/badid/haunt-plugin.toml"
set +e
HAUNT_PLUGINS_DIR="$DIR" HAUNT_FIRST_PARTY_PLUGINS="$T/badid" macos/bundle-plugins.sh "$T/first" tabs-plus 2>"$T/err"; code=$?
set -e
[ "$code" = 1 ] && grep -q "is not a plugin id" "$T/err" && [ ! -e "$T/first" ] || fail "bad id after a good repo: exit $code, $(cat "$T/err")"
echo "bundle-plugins: ok"
