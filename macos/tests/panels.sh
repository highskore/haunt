#!/bin/bash
# Plugin panels drawn offscreen, nothing shown: a canvas rect's sub line and a keyed shape mid-ease.
# HAUNT_PANEL_RENDER=<dir> also writes each as a PNG.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
swiftc -module-name PanelsTest macos/Sources/PluginPanels.swift macos/Sources/Draw.swift macos/Sources/Tokens.swift \
  macos/Sources/TokApp.swift macos/Sources/Theme.swift macos/Sources/Layers.swift macos/Sources/Effects.swift macos/Sources/Config.swift macos/Sources/Blank.swift macos/Sources/Keys.swift macos/tests/panels/main.swift -o build/panels-test
build/panels-test
