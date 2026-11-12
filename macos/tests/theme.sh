#!/bin/bash
# Theme files: lookup order, extends, validation, the user's keys over the theme's, and writing `theme =`.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
swiftc -module-name ThemeTest macos/Sources/Theme.swift macos/Sources/Layers.swift macos/Sources/Effects.swift macos/Sources/Tokens.swift macos/Sources/TokApp.swift \
  macos/Sources/Config.swift macos/Sources/Keys.swift macos/Sources/Blank.swift macos/tests/theme/main.swift -o build/theme-test
T=$(mktemp -d)
# Plugin fonts: one with a family of its own, and ones named like fonts every Mac has.
uv run --quiet --no-project --with fonttools python -I macos/tests/theme/font.py "$T/Own.ttf" "Haunt Theme Test"
uv run --quiet --no-project --with fonttools python -I macos/tests/theme/font.py "$T/Shadow.ttf" "Helvetica"
uv run --quiet --no-project --with fonttools python -I macos/tests/theme/font.py "$T/menlo.ttf" "menlo"
uv run --quiet --no-project --with fonttools python -I macos/tests/theme/font.py "$T/MenloSpace.ttf" "Menlo "
build/theme-test "$T"
