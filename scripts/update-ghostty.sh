#!/usr/bin/env bash
# Rebuild macos/deps/ from the official Ghostty source at the pinned tag.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY_TAG=v1.4.0
GHOSTTY_COMMIT=83fb95624b0439ee660c2679b43b38c8b63769cd
ZIG_VERSION=0.17.0
ZIG_SHA256=b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a
ZIG_PUBKEY=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U

TC="$ROOT/.toolchain"
SRC="$ROOT/deps-src/ghostty"
OUT="$ROOT/macos/deps"
ZIG="$TC/zig/zig"

if [[ ! -x "$ZIG" ]] || [[ "$("$ZIG" version)" != "$ZIG_VERSION" ]]; then
  mkdir -p "$TC/dl"
  tarball="zig-aarch64-macos-$ZIG_VERSION.tar.xz"
  curl -fsSL -o "$TC/dl/$tarball" "https://ziglang.org/download/$ZIG_VERSION/$tarball"
  curl -fsSL -o "$TC/dl/$tarball.minisig" "https://ziglang.org/download/$ZIG_VERSION/$tarball.minisig"
  echo "$ZIG_SHA256  $TC/dl/$tarball" | shasum -a 256 -c -
  minisign -Vm "$TC/dl/$tarball" -P "$ZIG_PUBKEY"
  rm -rf "$TC/zig" && tar -xf "$TC/dl/$tarball" -C "$TC" && mv "$TC/zig-aarch64-macos-$ZIG_VERSION" "$TC/zig"
fi

if [[ ! -d "$SRC/.git" ]]; then
  git clone --depth 1 --branch "$GHOSTTY_TAG" https://github.com/ghostty-org/ghostty.git "$SRC"
fi
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$GHOSTTY_COMMIT" ]] || { echo "ghostty commit mismatch" >&2; exit 1; }

# Keep every Zig artefact inside the repo.
export ZIG_GLOBAL_CACHE_DIR="$ROOT/.cache/zig-global"
cd "$SRC"
"$ZIG" build \
  --cache-dir "$ROOT/.cache/zig-local" \
  --prefix "$ROOT/.cache/ghostty-out" \
  -Doptimize=ReleaseFast \
  -Demit-macos-app=false \
  -Demit-xcframework=true \
  -Dxcframework-target=native

XCF="$SRC/macos/GhosttyKit.xcframework"
LIB="$(find "$XCF" -name '*.a' | head -1)"
rm -rf "$OUT" && mkdir -p "$OUT/lib" "$OUT/include" "$OUT/share"
cp "$LIB" "$OUT/lib/libghostty.a"
strip -S "$OUT/lib/libghostty.a"
cp -R "$(dirname "$LIB")/Headers/." "$OUT/include/"
cp -R "$ROOT/.cache/ghostty-out/share/." "$OUT/share/" 2>/dev/null || true
echo "$GHOSTTY_TAG $GHOSTTY_COMMIT" > "$OUT/GHOSTTY_VERSION"
nm "$OUT/lib/libghostty.a" 2>/dev/null | grep -q ' T _ghostty_init$' || { echo "_ghostty_init missing" >&2; exit 1; }
ls -l "$OUT/lib/libghostty.a"
