#!/bin/bash
# The title bar: a plugin's line is drawn whole or not at all.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
swiftc -module-name TitleBarTest -D HAUNT_FIXTURES macos/Sources/CoreAPI.swift \
  macos/Sources/Fixture.swift macos/Sources/Config.swift macos/Sources/Blank.swift macos/Sources/Keys.swift macos/Sources/Tokens.swift \
  macos/Sources/TokApp.swift macos/Sources/Theme.swift macos/Sources/Effects.swift macos/Sources/TabColors.swift \
  macos/Sources/Draw.swift macos/Sources/TitleBarView.swift \
  macos/tests/titlebar/main.swift -o build/titlebar-test
build/titlebar-test
