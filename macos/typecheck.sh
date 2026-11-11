#!/bin/bash
# Type-checks the app against the committed Ghostty headers; needs no libghostty.a link.
set -euo pipefail
cd "$(dirname "$0")"
# Without the UniFFI bindings this is the mock-core build, which always has fixtures.
swiftc -typecheck -enable-bare-slash-regex -module-name Haunt -D HAUNT_FIXTURES \
  -import-objc-header Vendor/Support/ObjCExceptionCatcher.h \
  Sources/*.swift Vendor/Ghostty/*.swift "Vendor/Ghostty/Surface View/"*.swift Vendor/Support/*.swift \
  -Xcc -fmodule-map-file=deps/include/module.modulemap -Xcc -Ideps/include -Xcc -IVendor/Support
