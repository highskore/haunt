#!/bin/bash
# Regenerates Sources/Tokens.swift from design/tokens.json; --check fails if it is stale.
set -euo pipefail
exec uv run --quiet --no-project python -I "$(dirname "$0")/tools/gen_tokens.py" "$@"
