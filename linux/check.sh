#!/bin/sh
# Runs the workspace tests offline.
set -eu
cd "$(dirname "$0")/.."
cargo test --workspace --locked --offline
