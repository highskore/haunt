#!/bin/bash
# make-app's plugin bundling: none by default, exactly what --plugins names, unknown names refused, each built
# from its plugins.lock pin, and a manifest for another plugin api refused before anything is built.
set -euo pipefail
cd "$(dirname "$0")/../.."
DIR="${HAUNT_PLUGINS_DIR:-$(pwd)/../haunt-plugins}"
if [ ! -f "$DIR/haunt-tabs-plus/haunt-plugin.toml" ]; then
  echo "bundle-plugins: skipped, haunt-tabs-plus not found in $DIR"
  exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T" target/plugin-src/.cargo' EXIT
fail() { echo "FAIL $*"; exit 1; }

macos/bundle-plugins.sh "$T/default" "" >/dev/null
[ ! -e "$T/default" ] || [ -z "$(ls -A "$T/default")" ] || fail "the default bundle has plugins: $(ls "$T/default")"
HAUNT_PLUGINS_DIR="$DIR" macos/bundle-plugins.sh "$T/none" none >/dev/null
[ ! -e "$T/none" ] || fail "none bundled something"

HAUNT_PLUGINS_DIR="$DIR" macos/bundle-plugins.sh "$T/tabs" tabs-plus >/dev/null
[ "$(ls "$T/tabs")" = dev.haunt.tabs-plus ] || fail "--plugins tabs-plus gave: $(ls "$T/tabs")"
grep -qx 'entry = "plugin.wasm"' "$T/tabs/dev.haunt.tabs-plus/haunt-plugin.toml" || fail "entry not rewritten"
[ -s "$T/tabs/dev.haunt.tabs-plus/plugin.wasm" ] || fail "no wasm"
# The manifest is the pinned commit's, whatever the working tree holds.
PIN=$(awk '$1 == "tabs-plus" { print $3 }' macos/plugins.lock)
git -C "$DIR/haunt-tabs-plus" show "$PIN:haunt-plugin.toml" | sed 's/^entry = .*/entry = "plugin.wasm"/' >"$T/pinned.toml"
cmp -s "$T/pinned.toml" "$T/tabs/dev.haunt.tabs-plus/haunt-plugin.toml" || fail "the bundled manifest isn't the pinned one"
[ -z "$(ls -A target/plugin-src)" ] || fail "the staged sources were left behind: $(ls target/plugin-src)"

set +e
HAUNT_PLUGINS_DIR="$DIR" macos/bundle-plugins.sh "$T/bad" tabs-plus,tabs 2>"$T/err"; code=$?
set -e
[ "$code" = 2 ] && grep -q "unknown plugin 'tabs'" "$T/err" && [ ! -e "$T/bad" ] || fail "unknown name: exit $code, $(cat "$T/err")"
# The names offered are the plugin repos, not the adapters or the template.
grep -q "tabs-plus, " "$T/err" && ! sed "s#$DIR##g" "$T/err" | grep -qE "claude|codex|template" || fail "offered: $(cat "$T/err")"
set +e
HAUNT_PLUGINS_DIR="$T/nowhere" macos/bundle-plugins.sh --check /dev/null tabs-plus 2>"$T/err"; code=$?
set -e
[ "$code" = 2 ] && grep -q "no pinned plugin repo at $T/nowhere/haunt-tabs-plus" "$T/err" || fail "missing repo: exit $code"
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
sed 's/^entry = .*/entry = "..\/escape.wasm"/' "$T/pinned.toml" >"$T/fake/haunt-plugin.toml"
sed 's/^id = .*/id = "{{id}}"/' "$T/pinned.toml" >"$T/placeholder/haunt-plugin.toml"
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
commit() { git -C "$1" -c commit.gpgsign=false -c user.name=t -c user.email=t@t commit -q "${@:2}"; }
git -C "$P" init -q && git -C "$P" add -A && commit "$P" -m theme
printf 'theme-glass x %s\n' "$(git -C "$P" rev-parse HEAD)" >"$T/theme.lock"
HAUNT_PLUGINS_DIR="$T/plugins" HAUNT_PLUGINS_LOCK="$T/theme.lock" macos/bundle-plugins.sh "$T/theme" all >/dev/null
G="$T/theme/dev.haunt.theme-glass"
[ "$(cd "$G" && find . -type f | sort | tr '\n' ' ')" = "./OFL.txt ./fonts/A.ttf ./haunt-plugin.toml ./theme.toml " ] ||
  fail "theme bundle: $(cd "$G" && find . -type f)"
cmp -s "$P/haunt-plugin.toml" "$G/haunt-plugin.toml" || fail "theme manifest changed"
git -C "$P" rm -rq fonts && ln -s "$T/outside" "$P/fonts" && echo font >"$T/outside/A.ttf" && git -C "$P" add fonts && commit "$P" -m link
printf 'theme-glass x %s\n' "$(git -C "$P" rev-parse HEAD)" >"$T/theme.lock"
set +e
HAUNT_PLUGINS_DIR="$T/plugins" HAUNT_PLUGINS_LOCK="$T/theme.lock" macos/bundle-plugins.sh "$T/linked" theme-glass 2>"$T/err"; code=$?
set -e
[ "$code" = 1 ] && grep -q "fonts/A.ttf is not a regular file inside it" "$T/err" || fail "symlinked font dir: exit $code, $(cat "$T/err")"

# Every repo is checked before any is built, and the id is [plugin]'s, read as TOML.
mkdir -p "$T/badid"
printf '[plugin]\nid = "Dev.Haunt.X"\nname = "X"\nversion = "0.1.0"\napi = "0.4"\nentry = "x.wasm"\n[contributes.theme]\nid = "dev.haunt.x"\n' >"$T/badid/haunt-plugin.toml"
set +e
HAUNT_PLUGINS_DIR="$DIR" HAUNT_FIRST_PARTY_PLUGINS="$T/badid" macos/bundle-plugins.sh "$T/first" tabs-plus 2>"$T/err"; code=$?
set -e
[ "$code" = 1 ] && grep -q "is not a plugin id" "$T/err" && [ ! -e "$T/first" ] || fail "bad id after a good repo: exit $code, $(cat "$T/err")"

# Pins: a name plugins.lock doesn't list is unknown, and a pin the clone lacks is refused.
mkdir -p "$T/repos"
git clone -q "$DIR/haunt-tabs-plus" "$T/repos/haunt-tabs-plus"
printf 'tabs-plus x %s\n' 0000000000000000000000000000000000000001 >"$T/missing.lock"
set +e
HAUNT_PLUGINS_DIR="$T/repos" HAUNT_PLUGINS_LOCK="$T/missing.lock" macos/bundle-plugins.sh --check /dev/null tabs-plus 2>"$T/err"; code=$?
set -e
[ "$code" = 1 ] && grep -q "doesn't have; fetch it" "$T/err" || fail "missing pin: exit $code, $(cat "$T/err")"
: >"$T/empty.lock"
set +e
HAUNT_PLUGINS_DIR="$T/repos" HAUNT_PLUGINS_LOCK="$T/empty.lock" macos/bundle-plugins.sh --check /dev/null tabs-plus 2>"$T/err"; code=$?
set -e
[ "$code" = 2 ] && grep -q "unknown plugin 'tabs-plus'" "$T/err" || fail "unpinned name: exit $code, $(cat "$T/err")"

# Cargo config can't steer a pinned build: not in the pinned source, not above where it is staged.
R="$T/repos/haunt-tabs-plus"
git -C "$R" checkout -q --detach "$PIN"
mkdir "$R/.cargo" && echo '[build]' >"$R/.cargo/config.toml" && git -C "$R" add .cargo && commit "$R" -m cargo
printf 'tabs-plus x %s\n' "$(git -C "$R" rev-parse HEAD)" >"$T/cargo.lock"
set +e
HAUNT_PLUGINS_DIR="$T/repos" HAUNT_PLUGINS_LOCK="$T/cargo.lock" macos/bundle-plugins.sh "$T/cargo" tabs-plus 2>"$T/err"; code=$?
set -e
[ "$code" = 1 ] && grep -q "refusing to build with .*/haunt-tabs-plus/.cargo in the way" "$T/err" && [ ! -e "$T/cargo" ] ||
  fail "pinned .cargo: exit $code, $(cat "$T/err")"
mkdir -p target/plugin-src/.cargo
set +e
HAUNT_PLUGINS_DIR="$DIR" macos/bundle-plugins.sh "$T/above" tabs-plus 2>"$T/err"; code=$?
set -e
rm -r target/plugin-src/.cargo
[ "$code" = 1 ] && grep -q "refusing to build with .*/target/plugin-src/.cargo in the way" "$T/err" && [ ! -e "$T/above" ] ||
  fail "planted .cargo: exit $code, $(cat "$T/err")"

# A pinned manifest for another plugin api fails make-app at once, before the long build.
git -C "$R" checkout -q --detach "$PIN"
sed -i '' 's/^api = .*/api = "9.9"/' "$R/haunt-plugin.toml"
commit "$R" -am "api 9.9"
printf 'tabs-plus x %s\n' "$(git -C "$R" rev-parse HEAD)" >"$T/api.lock"
set +e
HAUNT_PLUGINS_DIR="$T/repos" HAUNT_PLUGINS_LOCK="$T/api.lock" macos/make-app.sh --plugins tabs-plus >"$T/out" 2>"$T/err"; code=$?
set -e
[ "$code" != 0 ] && grep -q 'its manifest says api "9.9", this haunt supports' "$T/err" || fail "api mismatch: exit $code, $(cat "$T/err")"
! grep -q "built" "$T/out" || fail "make-app built before refusing: $(cat "$T/out")"
echo "bundle-plugins: ok"
