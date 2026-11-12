#!/bin/bash
# Plugin output in the app: the Dock tile and badge it sets, the voice path rendered to a buffer (never played),
# and the synthesised sounds. HAUNT_DOCK_RENDER=<dir> also writes each Dock state as a PNG.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
swiftc -module-name PluginFxTest macos/Sources/PluginFx.swift macos/Sources/Tokens.swift macos/Sources/TokApp.swift \
  macos/tests/pluginfx/main.swift -o build/pluginfx-test
build/pluginfx-test
