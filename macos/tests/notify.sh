#!/bin/bash
# Agent notifications and the menu bar menu: answer routing, note lifecycle, [notifications] toggles, menu grouping.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
swiftc -module-name NotifyTest -D HAUNT_FIXTURES macos/Sources/Notify.swift macos/Sources/AnswerKey.swift macos/Sources/NotifyCenter.swift macos/Sources/NotifyHold.swift macos/Sources/CoreAPI.swift \
  macos/Sources/Config.swift macos/Sources/Keys.swift macos/Sources/Tokens.swift macos/Sources/TokApp.swift \
  macos/Sources/TabColors.swift macos/Sources/Draw.swift macos/Sources/StatusMenu.swift macos/Sources/Fixture.swift \
  macos/Sources/TitleBarView.swift macos/Sources/Theme.swift macos/Sources/Effects.swift macos/tests/notify/main.swift -o build/notify-test
build/notify-test
