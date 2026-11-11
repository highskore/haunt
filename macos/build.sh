#!/bin/bash
# Compiles the app against macos/deps/libghostty.a and haunt-core's UniFFI bindings.
# HAUNT_CORE=mock builds build/macos/haunt-mock without Rust. HAUNT_FIXTURES=1 builds build/macos/haunt-fixtures, which adds the
# mockup fixtures (HAUNT_FIXTURE) and capture switches; the shipping binary has neither.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
[ -d Vendor ] || ./vendor.sh
./gen-tokens.sh >/dev/null

BIN="$ROOT/build/macos"
mkdir -p "$BIN"
OPT="${HAUNT_SWIFT_OPT:--O}"
CORE=()
NAME=haunt
FIXTURES=()
[ "${HAUNT_FIXTURES:-0}" = 1 ] && NAME=haunt-fixtures
# A mock core never lands where make-app looks for the shipping binary.
[ "${HAUNT_CORE:-real}" != real ] && NAME=haunt-mock
# MockCore is fixture code, so a mock-core build always has fixtures.
if [ "${HAUNT_FIXTURES:-0}" = 1 ] || [ "${HAUNT_CORE:-real}" != real ]; then FIXTURES=(-D HAUNT_FIXTURES); fi
if [ "${HAUNT_CORE:-real}" = real ]; then
  U="$ROOT/build/uniffi"
  # Always regenerate: stale bindings from an older core fail to compile. Cargo is a no-op when nothing changed.
  rm -rf "$U"
  "$ROOT/scripts/build-core.sh"
  CORE=(-D HAUNT_REAL_CORE "$U"/*.swift -Xcc -fmodule-map-file="$U/module.modulemap" "$ROOT/target/release/libhaunt_ffi.a")
fi

clang -c -mmacosx-version-min=14.0 -fobjc-arc -ObjC Vendor/Support/ObjCExceptionCatcher.m -o "$BIN/ObjCExceptionCatcher.o"

swiftc $OPT -wmo -enable-bare-slash-regex -module-name Haunt ${FIXTURES[@]+"${FIXTURES[@]}"} \
  -target arm64-apple-macos14.0 \
  -import-objc-header Vendor/Support/ObjCExceptionCatcher.h \
  Sources/*.swift Vendor/Ghostty/*.swift "Vendor/Ghostty/Surface View/"*.swift Vendor/Support/*.swift \
  "$BIN/ObjCExceptionCatcher.o" ${CORE[@]+"${CORE[@]}"} \
  -Xcc -fmodule-map-file=deps/include/module.modulemap -Xcc -Ideps/include -Xcc -IVendor/Support \
  deps/lib/libghostty.a \
  -framework AppKit -framework SwiftUI -framework Combine -framework Metal -framework MetalKit \
  -framework CoreVideo -framework QuartzCore -framework IOSurface -framework CoreText \
  -framework CoreGraphics -framework CoreFoundation -framework Carbon -framework UserNotifications \
  -framework UniformTypeIdentifiers -lc++ -Xlinker -dead_strip \
  -o "$BIN/$NAME"
echo "built $BIN/$NAME (core: ${HAUNT_CORE:-real})"
