#!/bin/bash
# The app's login-shell PATH lookup: marker parsing, spaces in PATH, and shells that linger or hang.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
swiftc -module-name LoginPathTest macos/Sources/LoginPath.swift macos/tests/loginpath/main.swift -o build/loginpath-test
build/loginpath-test "$(mktemp -d)"
