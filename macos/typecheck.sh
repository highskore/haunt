#!/bin/bash
# Type-checks the app against the committed Ghostty headers; needs no libghostty.a link.
set -euo pipefail
cd "$(dirname "$0")"
swiftc -typecheck -enable-bare-slash-regex -module-name Haunt \
  -import-objc-header Vendor/Support/ObjCExceptionCatcher.h \
  Sources/*.swift Vendor/Ghostty/*.swift "Vendor/Ghostty/Surface View/"*.swift Vendor/Support/*.swift \
  -Xcc -fmodule-map-file=deps/include/module.modulemap -Xcc -Ideps/include -Xcc -IVendor/Support
