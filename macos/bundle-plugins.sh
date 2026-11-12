#!/bin/bash
# Builds first-party plugins into <dest>/<id>/ (haunt-plugin.toml with entry = "plugin.wasm", and plugin.wasm); a
# data-only plugin gets its manifest as it is and the files its [contributes.theme] names, and nothing is built.
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
for repo in ${repos[@]+"${repos[@]}"}; do
  info=$(manifest_info "$repo/haunt-plugin.toml") || exit 1
  id=$(sed -n 1p <<<"$info")
  case "$ids" in *"|$id|"*) echo "$repo: another repo is also $id" >&2; exit 1 ;; esac
  ids="$ids$id|"
  if [ -z "$(sed -n 2p <<<"$info")" ]; then
    base=$(cd "$repo" && pwd -P)/
    while IFS= read -r f; do
      real=$(cd "$repo/$(dirname "$f")" 2>/dev/null && pwd -P)/
      [ -f "$repo/$f" ] && [ ! -L "$repo/$f" ] && [[ "$real" == "$base"* ]] ||
        { echo "$repo: $f is not a regular file inside it" >&2; exit 1; }
    done < <(sed -n '3,$p' <<<"$info")
  fi
  infos+=("$info")
done

i=0
for repo in ${repos[@]+"${repos[@]}"}; do
  info=${infos[$i]}
  i=$((i + 1))
  id=$(sed -n 1p <<<"$info")
  entry=$(sed -n 2p <<<"$info")
  mkdir -p "$DEST/$id"
  if [ -z "$entry" ]; then
    cp "$repo/haunt-plugin.toml" "$DEST/$id/haunt-plugin.toml"
    while IFS= read -r f; do
      mkdir -p "$DEST/$id/$(dirname "$f")"
      cp "$repo/$f" "$DEST/$id/$f"
    done < <(sed -n '3,$p' <<<"$info")
    echo "bundled plugin $id"
    continue
  fi
  (cd "$repo" && cargo build -q --release --target wasm32-wasip2)
  sed 's/^entry = .*/entry = "plugin.wasm"/' "$repo/haunt-plugin.toml" >"$DEST/$id/haunt-plugin.toml"
  cp "$repo/$entry" "$DEST/$id/plugin.wasm"
  echo "bundled plugin $id"
done
