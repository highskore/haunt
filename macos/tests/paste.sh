#!/bin/bash
# The paste confirmation preview: every control character visible, bracketed-paste ends called out.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
swiftc -module-name PasteTest macos/Sources/PastePreview.swift macos/tests/paste/main.swift -o build/paste-test
build/paste-test
