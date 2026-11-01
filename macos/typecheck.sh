#!/bin/bash
# Type-checks the app against Ghostty's source headers; needs no libghostty.a.
set -euo pipefail
cd "$(dirname "$0")"
U=../build/uniffi
swiftc -typecheck -enable-bare-slash-regex -module-name Haunt \
  -import-objc-header Vendor/Support/ObjCExceptionCatcher.h \
  Sources/*.swift Vendor/Ghostty/*.swift "Vendor/Ghostty/Surface View/"*.swift Vendor/Support/*.swift \
  $U/haunt_core.swift $U/haunt_ffi.swift \
  -Xcc -fmodule-map-file=../deps-src/ghostty/include/module.modulemap -Xcc -I../deps-src/ghostty/include \
  -Xcc -fmodule-map-file=$U/module.modulemap -Xcc -IVendor/Support
