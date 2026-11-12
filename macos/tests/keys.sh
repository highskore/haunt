#!/bin/bash
# The [keys] table: shortcut parsing, defaults, clashes, and the Ghostty unbinds they produce.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
swiftc -O -module-name KeysTest macos/Sources/Keys.swift macos/Sources/KeyGuard.swift macos/Sources/PluginKeys.swift macos/Sources/PluginHover.swift macos/Sources/Config.swift macos/Sources/Blank.swift macos/Sources/Tokens.swift \
  macos/Sources/TokApp.swift macos/Sources/Theme.swift macos/Sources/Layers.swift macos/Sources/Effects.swift \
  macos/tests/keys/main.swift -o build/keys-test
build/keys-test
