#!/bin/bash
# Compiles the app against macos/deps/libghostty.a and haunt-core's UniFFI bindings.
# HAUNT_CORE=mock builds without Rust; fixtures (HAUNT_FIXTURE) use MockCore in either build.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
[ -d Vendor ] || ./vendor.sh
./gen-tokens.sh >/dev/null

BIN="$ROOT/build/macos"
mkdir -p "$BIN"
OPT="${HAUNT_SWIFT_OPT:--O}"
CORE=()
if [ "${HAUNT_CORE:-real}" = real ]; then
  U="$ROOT/build/uniffi"
  # Always regenerate: stale bindings from an older core fail to compile. Cargo is a no-op when nothing changed.
  rm -rf "$U"
  "$ROOT/scripts/build-core.sh"
  CORE=(-D HAUNT_REAL_CORE "$U"/*.swift -Xcc -fmodule-map-file="$U/module.modulemap" "$ROOT/target/release/libhaunt_ffi.a")
fi

clang -c -mmacosx-version-min=14.0 -fobjc-arc -ObjC Vendor/Support/ObjCExceptionCatcher.m -o "$BIN/ObjCExceptionCatcher.o"

swiftc $OPT -enable-bare-slash-regex -module-name Haunt \
  -target arm64-apple-macos14.0 \
  -import-objc-header Vendor/Support/ObjCExceptionCatcher.h \
  Sources/*.swift Vendor/Ghostty/*.swift "Vendor/Ghostty/Surface View/"*.swift Vendor/Support/*.swift \
  "$BIN/ObjCExceptionCatcher.o" ${CORE[@]+"${CORE[@]}"} \
  -Xcc -fmodule-map-file=deps/include/module.modulemap -Xcc -Ideps/include -Xcc -IVendor/Support \
  deps/lib/libghostty.a \
  -framework AppKit -framework SwiftUI -framework Combine -framework Metal -framework MetalKit \
  -framework CoreVideo -framework QuartzCore -framework IOSurface -framework CoreText \
  -framework CoreGraphics -framework CoreFoundation -framework Carbon -framework UserNotifications \
  -framework UniformTypeIdentifiers -lc++ \
  -o "$BIN/haunt"
echo "built $BIN/haunt (core: ${HAUNT_CORE:-real})"
