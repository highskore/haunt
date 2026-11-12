#!/bin/bash
# The palette's selection across updates: kept on a refresh, back to the first row on new text.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
swiftc -module-name PaletteTest -D HAUNT_FIXTURES macos/Sources/Palette.swift macos/Sources/Tokens.swift macos/Sources/TokApp.swift \
  macos/Sources/Draw.swift macos/Sources/CoreAPI.swift macos/Sources/Fixture.swift macos/Sources/Config.swift macos/Sources/Blank.swift \
  macos/Sources/Keys.swift macos/Sources/Theme.swift macos/Sources/Effects.swift macos/Sources/TabColors.swift macos/Sources/TitleBarView.swift macos/Sources/ThemesWindow.swift macos/Sources/Setup.swift macos/Sources/HauntAlert.swift macos/Sources/LoginPath.swift macos/tests/palette/main.swift -o build/palette-test
build/palette-test
