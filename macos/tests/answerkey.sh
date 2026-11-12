#!/bin/bash
# Answer keystrokes: only the agents' fixed Allow/Deny keys are pressed; any other write is a paste.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
swiftc -module-name AnswerKeyTest -D HAUNT_FIXTURES macos/Sources/AnswerKey.swift macos/Sources/CoreAPI.swift \
  macos/Sources/Fixture.swift macos/Sources/Config.swift macos/Sources/Blank.swift macos/Sources/Keys.swift macos/Sources/Tokens.swift \
  macos/Sources/TokApp.swift macos/Sources/Theme.swift macos/Sources/Effects.swift macos/Sources/TabColors.swift \
  macos/Sources/Draw.swift macos/Sources/TitleBarView.swift \
  macos/tests/answerkey/main.swift -o build/answerkey-test
build/answerkey-test
