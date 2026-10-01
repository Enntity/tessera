#!/usr/bin/env bash
# The README screenshots, from made-up data only: a throwaway home folder (invented Claude and Codex
# conversations, scripts/demo/make-fixtures.py), a fresh data folder, mock agent CLIs in the
# terminals (scripts/demo/mock.sh), mock pages, and for the full board, fixed machine and account
# readings (scripts/demo/*.json). Nothing of yours is on the board.
# Usage: scripts/demo-shot.sh [readme|full] [out.png]   (default docs/tessera.png, docs/tessera-full.png)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
demo=$root/scripts/demo
board=${1:-readme}
case $board in
  readme) out=${2:-$root/docs/tessera.png} ;;
  full) out=${2:-$root/docs/tessera-full.png} ;;
  *) echo "usage: $0 [readme|full] [out.png]" >&2; exit 2 ;;
esac
# Under the package (no symlinks on the way), so folders in the made-up home read as ~/src/….
work=$root/.build/demo
rm -rf "$work"
home=$work/home
bin=$work/bin
mkdir -p "$home" "$work/data" "$bin" "$(dirname "$out")"
python3 "$demo/make-fixtures.py" "$home" $([[ $board == full ]] && echo full) >/dev/null
# Each mock answers to its tool's name, so its tile is recognised as that tool.
for tool in codex claude omp grok ssh npm agent; do ln -s "$demo/mock.sh" "$bin/$tool"; done
# An empty board to start from (no first-launch shell), and the accounts.
echo '{"tiles":[]}' > "$work/data/workspace.json"
if [[ $board == full ]]; then
  python3 -c 'import json, sys; print(json.dumps([{"id": a["id"], "kind": a["id"].replace("-plan", "Plan"), "name": a["name"]} for a in json.load(open(sys.argv[1]))]))' \
    "$demo/accounts.json" > "$work/data/providers.json"
else
  echo '[{"id":"codex-plan","kind":"codexPlan","name":"ChatGPT / Codex plan"},{"id":"claude-plan","kind":"claudePlan","name":"Claude plan"}]' \
    > "$work/data/providers.json"
fi

python3 -m http.server 8765 --bind 127.0.0.1 --directory "$demo" >/dev/null 2>&1 &
server=$!
app="$root/.build/app-debug/Tessera.app"
trap 'kill $server 2>/dev/null; pkill -f "$app/Contents/MacOS/Tessera" 2>/dev/null; rm -rf "$work"' EXIT
CONFIGURATION=debug TESSERA_APP_PATH="$app" "$root/scripts/build-app.sh" >/dev/null
# The development copy's own preferences: lane on, privacy off, no background plan checks.
defaults write org.enntity.tessera.dev tessera.lane -bool YES
defaults write org.enntity.tessera.dev tessera.privacy -bool NO
defaults write org.enntity.tessera.dev tessera.claudeUsageChecks -bool NO

src=$home/src
if [[ $board == full ]]; then
  actions="size=2200x1050;pace=0.3;select=Shell;cmd=w;vitals=$demo/vitals.json;accounts=$demo/accounts.json"
  actions+=";cwd=$src/ml/kestrel;launch=codex prefill;launch=codex moe;launch=omp accept"
  actions+=";cwd=$src/ml;launch=codex stream;launch=omp drift"
  actions+=";cwd=$src/ml/kestrel;launch=codex evict"
  actions+=";cwd=$src/infra/harbor;launch=codex rollout"
  actions+=";cwd=$src/orbit;launch=claude ttl;launch=codex limits;launch=codex review;launch=exec npm test;launch=claude migration"
  actions+=";cwd=$src/ml/echo;launch=claude backfill"
  actions+=";cwd=$src/web/quill;launch=grok thread"
  actions+=";cwd=$home;launch=ssh spark02 serve;launch=ssh spark04 train;launch=ssh spark03 smi"
  actions+=";url=127.0.0.1:8765/dashboard.html;url=127.0.0.1:8765/run.html"
  actions+=";wait=12;select=Speculative decoding;wait=8;shot=$out"
else
  actions="size=1680x1000;pace=0.3;select=Shell;cmd=w"
  actions+=";cwd=$src/api;launch=agent ask 'Refactor session TTL'"
  actions+=";cwd=$src/web;launch=agent work 'Build web bundle'"
  actions+=";cwd=$src/api;launch=exec agent fail 'Run test suite'"
  actions+=";cwd=$src/mobile;launch=agent done 'Compiler tests'"
  actions+=";cwd=$src/infra;launch=agent logs 'Tail API logs'"
  actions+=";url=127.0.0.1:8765/dashboard.html"
  actions+=";wait=10;dock=Tail API logs;select=Compiler tests;wait=8;shot=$out"
fi
rm -f "$out"
# Terminals get a plain sh whose prompt (set last, through ENV) says nothing about whose machine it
# is, with the mocks first on its PATH.
printf '%s\n' "PS1='\$ '" "PATH='$bin':\$PATH" > "$work/prompt.sh"
SHELL=/bin/sh ENV="$work/prompt.sh" CFFIXED_USER_HOME="$home" TESSERA_DATA_DIR="$work/data" TESSERA_DEBUG_ACTIONS="$actions" \
  "$app/Contents/MacOS/Tessera" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
for _ in $(seq 1 120); do [[ -s "$out" ]] && break; sleep 1; done
[[ -s "$out" ]] || { echo "no screenshot" >&2; exit 1; }
sleep 1
echo "$out"
