#!/bin/bash
# Git.swift against hostile .git contents: a FIFO HEAD, /dev/zero symlinks, an oversized HEAD.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
swiftc -module-name GitTest macos/Sources/Git.swift macos/tests/git/main.swift -o build/git-test
build/git-test
