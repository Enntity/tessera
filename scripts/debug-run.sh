#!/usr/bin/env bash
# Development: build, launch with debug actions, and write window snapshots to $1.
# Usage: scripts/debug-run.sh /tmp/snap.png "launch=htop;wait=2;open=terminal"
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
pkill -f "Tessera.app/Contents/MacOS/Tessera" 2>/dev/null || true
CONFIGURATION=debug "$root/scripts/build-app.sh" >/dev/null
TESSERA_SNAPSHOT="$1" TESSERA_DEBUG_ACTIONS="${2:-}" "$root/.build/app/Tessera.app/Contents/MacOS/Tessera" >/dev/null 2>&1 &
