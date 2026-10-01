#!/usr/bin/env bash
# The README screenshot, from made-up data only: a throwaway home folder (invented Claude and Codex
# conversations, scripts/demo/make-fixtures.py), a fresh data folder, mock agents in the terminals
# (scripts/demo/agent.sh) and a mock dashboard page. Nothing of yours is on the board.
# Usage: scripts/demo-shot.sh [out.png]   (default docs/tessera.png)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-$root/docs/tessera.png}
# Under the package (no symlinks on the way), so folders in the made-up home read as ~/code/….
work=$root/.build/demo
rm -rf "$work"
home=$work/home
mkdir -p "$home" "$work/data" "$(dirname "$out")"
python3 "$root/scripts/demo/make-fixtures.py" "$home" >/dev/null
# An empty board to start from (no first-launch shell), and the two plan cards.
echo '{"tiles":[]}' > "$work/data/workspace.json"
echo '[{"id":"codex-plan","kind":"codexPlan","name":"ChatGPT / Codex plan"},{"id":"claude-plan","kind":"claudePlan","name":"Claude plan"}]' \
  > "$work/data/providers.json"

python3 -m http.server 8765 --bind 127.0.0.1 --directory "$root/scripts/demo" >/dev/null 2>&1 &
server=$!
app="$root/.build/app-debug/Tessera.app"
trap 'kill $server 2>/dev/null; pkill -f "$app/Contents/MacOS/Tessera" 2>/dev/null; rm -rf "$work"' EXIT
CONFIGURATION=debug TESSERA_APP_PATH="$app" "$root/scripts/build-app.sh" >/dev/null
# The development copy's own preferences: lane on, privacy off, no background plan checks.
defaults write org.enntity.tessera.dev tessera.lane -bool YES
defaults write org.enntity.tessera.dev tessera.privacy -bool NO
defaults write org.enntity.tessera.dev tessera.claudeUsageChecks -bool NO

agent="$root/scripts/demo/agent.sh"
actions="size=1680x1000;pace=0.3;select=Shell;cmd=w"
actions+=";cwd=$home/code/api;launch=$agent 'Refactor session TTL' ask"
actions+=";cwd=$home/code/web;launch=$agent 'Build web bundle' work"
actions+=";cwd=$home/code/api;launch=exec $agent 'Run test suite' fail"
actions+=";cwd=$home/code/mobile;launch=$agent 'Compiler tests' done"
actions+=";cwd=$home/code/infra;launch=$agent 'Tail API logs' logs"
actions+=";url=127.0.0.1:8765/dashboard.html"
actions+=";wait=10;dock=Tail API logs;select=Compiler tests;wait=8;shot=$out"
rm -f "$out"
# Terminals get a plain sh whose prompt (set last, through ENV) says nothing about whose machine it is.
echo "PS1='\$ '" > "$work/prompt.sh"
SHELL=/bin/sh ENV="$work/prompt.sh" CFFIXED_USER_HOME="$home" TESSERA_DATA_DIR="$work/data" TESSERA_DEBUG_ACTIONS="$actions" \
  "$app/Contents/MacOS/Tessera" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
for _ in $(seq 1 90); do [[ -s "$out" ]] && break; sleep 1; done
[[ -s "$out" ]] || { echo "no screenshot" >&2; exit 1; }
sleep 1
echo "$out"
