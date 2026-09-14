#!/usr/bin/env bash
set -euo pipefail

# Backward-compatible local development entry point.
ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIGURATION="${CONFIGURATION:-debug}"

if [[ "$CONFIGURATION" == "debug" ]]; then
  exec "$ROOT/scripts/build-macos.sh" --debug
fi
exec "$ROOT/scripts/build-macos.sh" --release
