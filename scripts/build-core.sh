#!/bin/bash
# Builds haunt-ffi (static lib) and its Swift bindings into build/uniffi.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# Match the app's deployment target so ld does not warn on every Rust object.
export MACOSX_DEPLOYMENT_TARGET=14.0
cargo build --release -p haunt-ffi
cargo run -q --release -p haunt-ffi --bin uniffi-bindgen -- \
  generate --library target/release/libhaunt_ffi.a --language swift --out-dir build/uniffi
# Both crates' FFI headers in one modulemap so a single swiftc module sees them.
cat > build/uniffi/module.modulemap <<'MM'
module haunt_coreFFI { header "haunt_coreFFI.h"
 export * }
module haunt_ffiFFI { header "haunt_ffiFFI.h"
 export * }
MM
