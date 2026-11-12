#!/bin/bash
# Builds first-party plugins into <dest>/<id>/ (haunt-plugin.toml with entry = "plugin.wasm", and plugin.wasm); a
# data-only plugin gets its manifest as it is and the files its [contributes.theme] names, and nothing is built.
# Usage: bundle-plugins.sh [--check] <dest> <names>
#   names: comma-separated short names from macos/plugins.lock (today allowlist, commands, decision-log,
#   tabs-plus, theme-glass, theme-sigil, theme-win95), each the repo haunt-plugins/haunt-<name>, or all / none (the default
#   is none). --check only validates the names, their pins and their manifests' api, before anything is built.
# Each plugin is built from the commit plugins.lock pins, taken with git archive, never from the working tree,
# and its manifest's api must be the one this haunt supports. HAUNT_PLUGINS_UNPINNED=1 builds the working
# trees instead, while iterating. HAUNT_PLUGINS_DIR is where the named repos live (default ../haunt-plugins);
# HAUNT_PLUGINS_LOCK replaces plugins.lock (tests). HAUNT_FIRST_PARTY_PLUGINS adds explicit repo paths, built
# unpinned with a warning, skipped with one when missing.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
CHECK=""
[ "${1:-}" = --check ] && { CHECK=1; shift; }
DEST="${1:?usage: bundle-plugins.sh [--check] <dest> <names>}"
NAMES="${2:-}"
DIR="${HAUNT_PLUGINS_DIR:-$ROOT/../haunt-plugins}"
LOCK="${HAUNT_PLUGINS_LOCK:-$PWD/plugins.lock}"
UNPINNED="${HAUNT_PLUGINS_UNPINNED:-}"
# The plugin API this haunt supports, as major.minor.
API=$(sed -n 's/^pub const API: (u64, u64) = (\([0-9]*\), \([0-9]*\));$/\1.\2/p' "$ROOT/core/src/plugin_manifest.rs")
[ -n "$API" ] || { echo "can't read the plugin API from core/src/plugin_manifest.rs" >&2; exit 1; }

# A plugin repo: a manifest with a real id, which leaves out the adapters and the template's placeholder.
is_plugin() { grep -qE '^id = "[a-z0-9]+(\.[a-z0-9-]+)+"$' "$1/haunt-plugin.toml" 2>/dev/null; }
pin() { awk -v n="$1" '$1 == n { print $3 }' "$LOCK"; }

available() {
  if [ -n "$UNPINNED" ]; then
    for r in "$DIR"/haunt-*; do is_plugin "$r" && printf '%s, ' "${r##*/haunt-}"; done
  else
    awk '!/^#/ && NF == 3 { printf "%s, ", $1 }' "$LOCK"
  fi
  return 0
}

# The manifest a build would use: at the pin, or in the working tree.
manifest() {
  if [ -n "$2" ]; then git -C "$1" show "$2:haunt-plugin.toml"; else cat "$1/haunt-plugin.toml"; fi
}

# api_ok <label> <manifest text>: the same major.minor as this haunt's.
api_ok() {
  local api
  api=$(sed -n 's/^api = "\([0-9]*\.[0-9]*\)\(\.[0-9]*\)\{0,1\}"$/\1/p' <<<"$2" | head -1)
  [ "$api" = "$API" ] && return 0
  echo "$1: its manifest says api \"${api:-?}\", this haunt supports $API; pin a commit for $API" >&2
  return 1
}

repos=()
revs=()
seen=""
# add <repo> <rev>: each repo once, by its real path, whether named twice, by `all` or again in
# HAUNT_FIRST_PARTY_PLUGINS. An empty rev builds the working tree.
add() {
  local real
  real=$(cd "$1" && pwd -P)
  case "$seen" in *"|$real|"*) return 0 ;; esac
  seen="$seen|$real|"
  repos+=("$real")
  revs+=("$2")
}

# named <name>: checks the repo, its pin and its api, then adds it.
named() {
  local n="$1" repo="$DIR/haunt-$1" rev=""
  if [[ ! "$n" =~ ^[a-z0-9][a-z0-9-]*$ ]] || ! { [ -n "$UNPINNED" ] || [ -n "$(pin "$n")" ]; } || ! is_plugin "$repo"; then
    echo "unknown plugin '$n': no pinned plugin repo at $repo; choose from $(available)all or none" >&2
    exit 2
  fi
  if [ -z "$UNPINNED" ]; then
    rev=$(pin "$n")
    if ! git -C "$repo" cat-file -e "$rev^{commit}" 2>/dev/null; then
      echo "$n: plugins.lock pins ${rev:0:7}, which $repo doesn't have; fetch it" >&2
      exit 1
    fi
  fi
  api_ok "$n" "$(manifest "$repo" "$rev")" || exit 1
  add "$repo" "$rev"
}

IFS=, read -ra names <<<"$NAMES"
for n in ${names[@]+"${names[@]}"}; do
  n="${n// /}"
  case "$n" in
    "" | none) ;;
    all)
      if [ -n "$UNPINNED" ]; then
        for r in "$DIR"/haunt-*; do is_plugin "$r" && named "${r##*/haunt-}"; done
      else
        for p in $(awk '!/^#/ && NF == 3 { print $1 }' "$LOCK"); do named "$p"; done
      fi
      ;;
    *) named "$n" ;;
  esac
done
[ -n "$CHECK" ] && exit 0
read -ra extra <<<"${HAUNT_FIRST_PARTY_PLUGINS:-}"
for repo in ${extra[@]+"${extra[@]}"}; do
  if is_plugin "$repo"; then
    case "$seen" in *"|$(cd "$repo" && pwd -P)|"*) continue ;; esac
    echo "warning: bundling $repo unpinned" >&2
    api_ok "$repo" "$(manifest "$repo" "")" || exit 1
    add "$repo" ""
  else
    echo "no plugin with a real id at $repo; building without it" >&2
  fi
done
[ -n "$UNPINNED" ] && [ ${#repos[@]} -gt 0 ] && echo "warning: bundling the plugin working trees unpinned" >&2
[ ${#repos[@]} -eq 0 ] && exit 0

# Pinned sources are unpacked inside this checkout's target, not a shared temp folder, where anyone could plant a
# .cargo/config.toml or rust-toolchain above them for cargo to find; every build uses our own toolchain.
mkdir -p "$ROOT/target/plugin-src" "$ROOT/target/plugins"
STAGE=$(mktemp -d "$ROOT/target/plugin-src/XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
TOOLCHAIN=$(sed -n 's/^channel = "\(.*\)"$/\1/p' "$ROOT/rust-toolchain.toml")
[ -n "$TOOLCHAIN" ] || { echo "can't read the toolchain from rust-toolchain.toml" >&2; exit 1; }
# Cargo looks for config above a staged source, up to the checkout that owns target (which may be a shared one).
TOP=$(cd -P "$ROOT/target/.." && pwd)

# planted <src>: prints a .cargo in the source or above it up to $TOP, or a toolchain file in between.
planted() {
  local d
  [ -e "$1/.cargo" ] && { echo "$1/.cargo"; return 0; }
  d=$(cd "$1/.." && pwd -P)
  while [ "$d" != "$TOP" ]; do
    [ "$d" = / ] && { echo "a stage outside $TOP"; return 0; }
    [ -e "$d/.cargo" ] && { echo "$d/.cargo"; return 0; }
    compgen -G "$d/rust-toolchain*" >/dev/null && { echo "$d/rust-toolchain"; return 0; }
    d=$(dirname "$d")
  done
  [ -e "$TOP/.cargo" ] && { echo "$TOP/.cargo"; return 0; }
  return 1
}

srcs=()
for i in "${!repos[@]}"; do
  src="${repos[$i]}"
  if [ -n "${revs[$i]}" ]; then
    src="$STAGE/$(basename "${repos[$i]}")"
    mkdir "$src"
    git -C "${repos[$i]}" archive "${revs[$i]}" | tar -x -C "$src"
    if p=$(planted "$src"); then
      echo "${repos[$i]}: refusing to build with $p in the way" >&2
      exit 1
    fi
    # Its own target: plugin crates share a name, and cargo would take one's wasm as another's, fresh.
    mkdir -p "$ROOT/target/plugins/$(basename "${repos[$i]}")"
    ln -s "$ROOT/target/plugins/$(basename "${repos[$i]}")" "$src/target"
  fi
  srcs+=("$src")
done

# A repo's [plugin] id and entry, then the files a data-only plugin's [contributes.theme] names, one per line.
# Fails unless the id is valid and every path is plain and relative.
manifest_info() {
  uv run --quiet --no-project python -I -c '
import pathlib, re, sys, tomllib
m = tomllib.load(open(sys.argv[1], "rb"))
p = m.get("plugin", {})
pid, entry = p.get("id", ""), p.get("entry", "")
if not isinstance(pid, str) or len(pid) > 128 or not re.fullmatch(r"[a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9-]*)+", pid):
    sys.exit(f"{sys.argv[1]}: id {pid!r} is not a plugin id")
def plain(f):
    q = pathlib.PurePosixPath(f)
    return isinstance(f, str) and re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9._/-]*", f) and not q.is_absolute() and ".." not in q.parts
if entry and not plain(entry):
    sys.exit(f"{sys.argv[1]}: entry {entry!r} must be a relative path inside the repo")
print(pid)
print(entry)
if not entry:
    t = m.get("contributes", {}).get("theme", {})
    for f in [t.get("file", "")] + t.get("fonts", []) + t.get("licenses", []):
        if not f or not plain(f):
            sys.exit(f"{sys.argv[1]}: {f!r} is not a file inside the plugin folder")
        print(f)
' "$1"
}

# Every repo is checked before any is built.
ids="|"
infos=()
for i in "${!repos[@]}"; do
  repo="${repos[$i]}" src="${srcs[$i]}"
  info=$(manifest_info "$src/haunt-plugin.toml") || exit 1
  id=$(sed -n 1p <<<"$info")
  case "$ids" in *"|$id|"*) echo "$repo: another repo is also $id" >&2; exit 1 ;; esac
  ids="$ids$id|"
  if [ -z "$(sed -n 2p <<<"$info")" ]; then
    base=$(cd "$src" && pwd -P)/
    while IFS= read -r f; do
      real=$(cd "$src/$(dirname "$f")" 2>/dev/null && pwd -P)/
      [ -f "$src/$f" ] && [ ! -L "$src/$f" ] && [[ "$real" == "$base"* ]] ||
        { echo "$repo: $f is not a regular file inside it" >&2; exit 1; }
    done < <(sed -n '3,$p' <<<"$info")
  fi
  infos+=("$info")
done

for i in "${!repos[@]}"; do
  src="${srcs[$i]}" rev="${revs[$i]}" info="${infos[$i]}"
  id=$(sed -n 1p <<<"$info")
  entry=$(sed -n 2p <<<"$info")
  mkdir -p "$DEST/$id"
  if [ -z "$entry" ]; then
    cp "$src/haunt-plugin.toml" "$DEST/$id/haunt-plugin.toml"
    while IFS= read -r f; do
      mkdir -p "$DEST/$id/$(dirname "$f")"
      cp "$src/$f" "$DEST/$id/$f"
    done < <(sed -n '3,$p' <<<"$info")
  else
    # A CARGO_TARGET_DIR (relative to the source, as cargo reads it) holds what the entry's target/ would, one
    # folder per plugin there too.
    tdir=""
    if [ -n "${CARGO_TARGET_DIR:-}" ]; then
      tdir="$CARGO_TARGET_DIR"
      [[ "$tdir" == /* ]] || tdir="$src/$tdir"
      tdir="$tdir/$(basename "${repos[$i]}")"
    fi
    # Our toolchain, whatever the plugin's own rust-toolchain file says.
    (cd "$src" && { [ -z "$tdir" ] || export CARGO_TARGET_DIR="$tdir"; } && RUSTUP_TOOLCHAIN="$TOOLCHAIN" cargo build -q --release --target wasm32-wasip2)
    sed 's/^entry = .*/entry = "plugin.wasm"/' "$src/haunt-plugin.toml" >"$DEST/$id/haunt-plugin.toml"
    wasm="$src/$entry"
    [ -n "$tdir" ] && [[ "$entry" == target/* ]] && wasm="$tdir/${entry#target/}"
    cp "$wasm" "$DEST/$id/plugin.wasm"
  fi
  echo "bundled plugin $id${rev:+ at ${rev:0:7}}"
done
