#!/bin/bash
# Builds first-party plugins into <dest>/<id>/ (haunt-plugin.toml with entry = "plugin.wasm", and plugin.wasm).
# Usage: bundle-plugins.sh [--check] <dest> <names>
#   names: comma-separated short names, each the repo haunt-plugins/haunt-<name> (today allowlist, commands,
#   decision-log, tabs-plus), or all / none (the default is none).
#   --check only validates the names: each must be a plugin repo in HAUNT_PLUGINS_DIR.
# HAUNT_PLUGINS_DIR is where the named repos live (default ../haunt-plugins); HAUNT_FIRST_PARTY_PLUGINS adds
# explicit repo paths, skipped with a warning when missing.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
CHECK=""
[ "${1:-}" = --check ] && { CHECK=1; shift; }
DEST="${1:?usage: bundle-plugins.sh [--check] <dest> <names>}"
NAMES="${2:-}"
DIR="${HAUNT_PLUGINS_DIR:-$ROOT/../haunt-plugins}"

# A plugin repo: a manifest with a real id, which leaves out the adapters and the template's placeholder.
is_plugin() { grep -qE '^id = "[a-z0-9]+(\.[a-z0-9-]+)+"$' "$1/haunt-plugin.toml" 2>/dev/null; }

available() {
  for r in "$DIR"/haunt-*; do is_plugin "$r" && printf '%s, ' "${r##*/haunt-}"; done
  return 0
}

repos=()
seen=""
# Each repo once, by its real path, whether named twice, by `all` or again in HAUNT_FIRST_PARTY_PLUGINS.
add() {
  local real
  real=$(cd "$1" && pwd -P)
  case "$seen" in *"|$real|"*) return 0 ;; esac
  seen="$seen|$real|"
  repos+=("$real")
}

IFS=, read -ra names <<<"$NAMES"
for n in ${names[@]+"${names[@]}"}; do
  n="${n// /}"
  case "$n" in
    "" | none) ;;
    all) for r in "$DIR"/haunt-*; do is_plugin "$r" && add "$r"; done ;;
    *)
      if [[ ! "$n" =~ ^[a-z0-9][a-z0-9-]*$ ]] || ! is_plugin "$DIR/haunt-$n"; then
        echo "unknown plugin '$n': no plugin repo at $DIR/haunt-$n; choose from $(available)all or none" >&2
        exit 2
      fi
      add "$DIR/haunt-$n"
      ;;
  esac
done
[ -n "$CHECK" ] && exit 0
read -ra extra <<<"${HAUNT_FIRST_PARTY_PLUGINS:-}"
for repo in ${extra[@]+"${extra[@]}"}; do
  if is_plugin "$repo"; then add "$repo"; else echo "no plugin with a real id at $repo; building without it" >&2; fi
done

ids="|"
for repo in ${repos[@]+"${repos[@]}"}; do
  id=$(sed -n 's/^id = "\(.*\)"$/\1/p' "$repo/haunt-plugin.toml" | head -1)
  entry=$(sed -n 's/^entry = "\(.*\)"$/\1/p' "$repo/haunt-plugin.toml" | head -1)
  # The entry is copied from inside the repo: a plain relative path, no `..`.
  if [[ ! "$entry" =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ ]] || [[ "/$entry/" == */../* ]]; then
    echo "$repo: entry '$entry' must be a relative path inside the repo" >&2
    exit 1
  fi
  case "$ids" in *"|$id|"*) echo "$repo: another repo is also $id" >&2; exit 1 ;; esac
  ids="$ids$id|"
  (cd "$repo" && cargo build -q --release --target wasm32-wasip2)
  mkdir -p "$DEST/$id"
  sed 's/^entry = .*/entry = "plugin.wasm"/' "$repo/haunt-plugin.toml" >"$DEST/$id/haunt-plugin.toml"
  cp "$repo/$entry" "$DEST/$id/plugin.wasm"
  echo "bundled plugin $id"
done
