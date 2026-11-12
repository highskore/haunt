#!/bin/bash
# The theme pickers, ⌘K and the Themes window: selecting previews, keeping writes it, anything else puts the old one back.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
swiftc -module-name ThemePickerTest -D HAUNT_FIXTURES macos/Sources/Palette.swift macos/Sources/Tokens.swift macos/Sources/TokApp.swift \
  macos/Sources/Draw.swift macos/Sources/CoreAPI.swift macos/Sources/Fixture.swift macos/Sources/Config.swift macos/Sources/Blank.swift \
  macos/Sources/Keys.swift macos/Sources/Theme.swift macos/Sources/Effects.swift macos/Sources/TabColors.swift macos/Sources/TitleBarView.swift macos/Sources/ThemesWindow.swift macos/Sources/Setup.swift macos/Sources/LoginPath.swift macos/tests/themepicker/main.swift -o build/themepicker-test
build/themepicker-test
