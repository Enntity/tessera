#!/usr/bin/env bash
# Development: build a debug copy, launch it with scripted actions, and write window captures to $1.
# Runs from its own bundle and data folder, so a Tessera you're actually using is left alone.
# Usage: scripts/debug-run.sh /tmp/snap.png "launch=htop;wait=2;open=terminal"
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
app="$root/.build/app-debug/Tessera.app"
pkill -f "$app/Contents/MacOS/Tessera" 2>/dev/null || true
CONFIGURATION=debug TESSERA_APP_PATH="$app" "$root/scripts/build-app.sh" >/dev/null
mkdir -p "$root/.build/debug-data"
TESSERA_DATA_DIR="$root/.build/debug-data" TESSERA_SNAPSHOT="$1" TESSERA_DEBUG_ACTIONS="${2:-}" \
  "$app/Contents/MacOS/Tessera" >/dev/null 2>&1 &
