#!/bin/bash
# Sidebar drag targets: where a dropped row lands, and that nothing lands in NEEDS YOU; the agents view's restored frame.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
swiftc -module-name SidebarTest -D HAUNT_FIXTURES macos/Sources/SidebarView.swift macos/Sources/Tokens.swift macos/Sources/TokApp.swift macos/Sources/TabColors.swift \
  macos/Sources/Draw.swift macos/Sources/CoreAPI.swift macos/Sources/Fixture.swift macos/Sources/TitleBarView.swift \
  macos/Sources/Config.swift macos/Sources/Keys.swift macos/Sources/AgentsView.swift \
  macos/tests/sidebar/main.swift -o build/sidebar-test
build/sidebar-test
