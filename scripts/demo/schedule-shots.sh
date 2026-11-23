#!/usr/bin/env bash
# The Schedules UI shots — a tile's schedule line and the overseer's Schedules list — from made-up
# data only: a throwaway home, a fresh data folder, the mock `claude` (scripts/demo/mock.sh), and a
# debug action feeding invented Accord schedules (TESSERA_DEBUG_ACTIONS schedules=<file>). No
# coordinator is contacted. Usage: scripts/demo/schedule-shots.sh [outdir]
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
demo=$root/scripts/demo
work=${1:-$root/.build/schedule-demo}
rm -rf "$work"
home=$work/home
bin=$work/bin
data=$work/data
mkdir -p "$home" "$data" "$bin"
for tool in codex claude omp grok; do ln -s "$demo/mock.sh" "$bin/$tool"; done
echo '{"tiles":[]}' > "$data/workspace.json"
echo '[{"id":"claude-plan","kind":"claudePlan","name":"Claude plan"}]' > "$data/providers.json"
printf '%s\n' "PS1='\$ '" "PATH='$bin':\$PATH" > "$work/prompt.sh"

cat > "$work/schedules.json" <<'JSON'
{"agentAddress": "demo/claude-agent", "tile": "selected", "schedules": [
 {"id": "sched-check", "state": "active", "owner": "demo/jason", "ownerLabel": "jason",
  "to": "demo/claude-agent", "trigger": "every 10m", "persistent": true,
  "text": "Scheduled by jason: check Messenger"},
 {"id": "sched-review", "state": "paused", "owner": "demo/jason", "ownerLabel": "jason",
  "to": "demo/claude-agent", "trigger": "at 2026-11-24T08:00:00Z",
  "text": "Scheduled by jason: review the night shift"},
 {"id": "sched-status", "state": "active", "owner": "demo/ops", "ownerLabel": "ops",
  "to": "demo/status-agent", "trigger": "topic:deploys",
  "text": "Scheduled by ops: refresh the status page"},
 {"id": "sched-old", "state": "done", "owner": "demo/jason",
  "to": "demo/claude-agent", "trigger": "every 5m", "text": "must not be listed"}]}
JSON

app="$root/.build/app-debug/Tessera.app"
trap 'pkill -f "$app/Contents/MacOS/Tessera" 2>/dev/null' EXIT
CONFIGURATION=debug TESSERA_APP_PATH="$app" "$root/scripts/build-app.sh" >/dev/null
defaults write org.enntity.tessera.dev tessera.lane -bool YES
defaults write org.enntity.tessera.dev tessera.privacy -bool NO
defaults write org.enntity.tessera.dev tessera.claudeUsageChecks -bool NO

last="$work/overseer-schedules.png"
SHELL=/bin/sh ENV="$work/prompt.sh" CFFIXED_USER_HOME="$home" TESSERA_DATA_DIR="$data" \
  TESSERA_SCHEDULES_OPEN=1 \
  TESSERA_DEBUG_ACTIONS="size=1680x1000;pace=0.3;launch=claude;wait=5;schedules=$work/schedules.json;wait=2;shot=$work/tile-schedule.png;overseercmd=claude;ask;wait=5;shot=$last" \
  "$app/Contents/MacOS/Tessera" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
for _ in $(seq 1 120); do [[ -s $last ]] && break; sleep 1; done
pkill -f "$app/Contents/MacOS/Tessera" 2>/dev/null || true
sleep 1
[[ -s $work/tile-schedule.png && -s $last ]] || { echo "missing a screenshot in $work" >&2; exit 1; }
ls -1 "$work"/*.png
