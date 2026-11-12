#!/bin/bash
# The review screen's data: diff parsing, a real git run in a temp repo, checks, the drafted prompt and its sanitising.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
swiftc -D DEBUG -module-name ReviewTest macos/Sources/CoreAPI.swift macos/Sources/PastePreview.swift macos/Sources/Blank.swift macos/Sources/GitDiff.swift \
  macos/Sources/ReviewModel.swift macos/tests/review/fixture-stub.swift macos/tests/review/main.swift -o build/review-test
build/review-test
