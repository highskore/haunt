#!/bin/bash
# Compiles the app (app sources + vendored wrapper + UniFFI bindings) against macos/deps/libghostty.a.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
[ -d Vendor ] || ./vendor.sh
[ -f "$ROOT/build/uniffi/haunt_ffi.swift" ] || "$ROOT/scripts/build-core.sh"

BIN="$ROOT/build/macos"
mkdir -p "$BIN"
U="$ROOT/build/uniffi"
OPT="${HAUNT_SWIFT_OPT:--O}"

clang -c -fobjc-arc -ObjC Vendor/Support/ObjCExceptionCatcher.m -o "$BIN/ObjCExceptionCatcher.o"

swiftc $OPT -enable-bare-slash-regex -module-name Haunt \
  -target arm64-apple-macos14.0 \
  -import-objc-header Vendor/Support/ObjCExceptionCatcher.h \
  Sources/*.swift Vendor/Ghostty/*.swift "Vendor/Ghostty/Surface View/"*.swift Vendor/Support/*.swift \
  "$U/haunt_core.swift" "$U/haunt_ffi.swift" "$BIN/ObjCExceptionCatcher.o" \
  -Xcc -fmodule-map-file=deps/include/module.modulemap -Xcc -Ideps/include \
  -Xcc -fmodule-map-file="$U/module.modulemap" -Xcc -IVendor/Support \
  deps/lib/libghostty.a "$ROOT/target/release/libhaunt_ffi.a" \
  -framework AppKit -framework SwiftUI -framework Combine -framework Metal -framework MetalKit \
  -framework CoreVideo -framework QuartzCore -framework IOSurface -framework CoreText \
  -framework CoreGraphics -framework CoreFoundation -framework Carbon -framework UserNotifications \
  -framework UniformTypeIdentifiers -lc++ \
  -o "$BIN/Haunt"
echo "built $BIN/Haunt"
