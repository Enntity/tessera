#!/usr/bin/env bash
# The overseer-chat screenshots, from made-up data only: a throwaway home, a fresh data folder, the
# mock `claude` as the overseer's agent (scripts/demo/mock.sh's overseer mode), and a hand-written
# Claude transcript for the conversation shots. Nothing real is started; nothing touches docs/.
# Usage: scripts/demo/overseer-shots.sh [outdir]   (default .build/overseer-demo)
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
demo=$root/scripts/demo
work=${1:-$root/.build/overseer-demo}
rm -rf "$work"
home=$work/home
bin=$work/bin
data=$work/data
mkdir -p "$home" "$data" "$bin"
for tool in codex claude omp grok ssh npm agent; do ln -s "$demo/mock.sh" "$bin/$tool"; done
echo '{"tiles":[]}' > "$data/workspace.json"
echo '[{"id":"claude-plan","kind":"claudePlan","name":"Claude plan"}]' > "$data/providers.json"
printf '%s\n' "PS1='\$ '" "PATH='$bin':\$PATH" > "$work/prompt.sh"

app="$root/.build/app-debug/Tessera.app"
trap 'pkill -f "$app/Contents/MacOS/Tessera" 2>/dev/null' EXIT
CONFIGURATION=debug TESSERA_APP_PATH="$app" "$root/scripts/build-app.sh" >/dev/null
defaults write org.enntity.tessera.dev tessera.lane -bool YES
defaults write org.enntity.tessera.dev tessera.privacy -bool NO
defaults write org.enntity.tessera.dev tessera.claudeUsageChecks -bool NO

slug=$(echo -n "$data/overseer" | tr -c 'a-zA-Z0-9' '-')

# One scripted run of the debug app with the overseer's mock in `state` (idle | working | asking);
# returns once the last shot in `actions` is written.
run() {
  local state=$1 actions=$2 last=$3
  echo -n "$state" > "$work/overseer-state"
  rm -f "$last"
  OVERSEER_STATE_FILE="$work/overseer-state" OVERSEER_ID_FILE="$work/overseer-id" \
  SHELL=/bin/sh ENV="$work/prompt.sh" CFFIXED_USER_HOME="$home" TESSERA_DATA_DIR="$data" TESSERA_DEBUG_ACTIONS="$actions" \
    "$app/Contents/MacOS/Tessera" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
  for _ in $(seq 1 120); do [[ -s $last ]] && break; sleep 1; done
  pkill -f "$app/Contents/MacOS/Tessera" 2>/dev/null || true
  sleep 1
  [[ -s $last ]] || { echo "no screenshot: $last" >&2; exit 1; }
}

# Run 1: the panel before the overseer has said anything — its empty state.
run idle "size=1680x1000;pace=0.3;overseercmd=claude;ask;wait=4;shot=$work/panel-empty.png" "$work/panel-empty.png"

# Its session id is known now: write the transcript the chat shots read.
id=$(cat "$work/overseer-id")
folder="$home/.claude/projects/$slug"
mkdir -p "$folder"
cat > "$folder/$id.jsonl" <<JSONL
{"type":"user","uuid":"u1","message":{"role":"user","content":"What's stuck, and why?"}}
{"type":"assistant","uuid":"a1","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"mcp__tessera__board","input":{}}]}}
{"type":"user","uuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"3 tiles waiting, 2 running"}]}}
{"type":"assistant","uuid":"a2","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t2","name":"mcp__tessera__read_tile","input":{"id":"kestrel-evict"}}]}}
{"type":"user","uuid":"r2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"evict: exit code 1"}]}}
{"type":"assistant","uuid":"a2b","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t3","name":"mcp__accord__accord_find","input":{"query":"spark lease"}}]}}
{"type":"user","uuid":"r3","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","content":"harbor holds spark02"}]}}
{"type":"assistant","uuid":"a3","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Two things are stuck:\n\n- **kestrel** — the evict job failed (exit 1)\n- harbor — waiting on a Spark lease for 40m"}]}}
{"type":"user","uuid":"u2","message":{"role":"user","content":"Who's using the Sparks?"}}
{"type":"assistant","uuid":"a4","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"spark02 serves the web tile; spark04 is idle."}]}}
JSONL

# Run 2: the card while it works, with a reply not yet read; then the panel over the conversation.
defaults write org.enntity.tessera.dev tessera.overseerSeenReply -string "a2-0"
run working "size=1680x1000;pace=0.3;brief=Two tiles are waiting on you: evict failed, harbor wants a Spark.;wait=7;shot=$work/board-card-unread.png;ask;wait=4;shot=$work/panel-chat.png;click=240,172;wait=1;shot=$work/panel-chat-expanded.png" "$work/panel-chat-expanded.png"

# Run 3: the card at rest — the reply was seen, so the brief shows.
defaults write org.enntity.tessera.dev tessera.overseerSeenReply -string "a4-0"
run idle "size=1680x1000;pace=0.3;brief=Two tiles are waiting on you: evict failed, harbor wants a Spark.;wait=5;shot=$work/board-card.png" "$work/board-card.png"

# Run 4: the overseer is asking in its terminal — the panel shows it, with the banner.
run asking "size=1680x1000;pace=0.3;ask;wait=6;shot=$work/panel-asking.png" "$work/panel-asking.png"

defaults delete org.enntity.tessera.dev tessera.overseerSeenReply 2>/dev/null || true
ls -1 "$work"/*.png
