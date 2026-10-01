#!/bin/bash
# Made-up agent CLIs for the README screenshots. Linked as codex, claude, omp, grok, ssh and npm in a
# folder put first on the demo's PATH, so each tile is recognised as that tool; as `agent <scene>
# <title>` for the simpler board. Each scene draws a believable screen and ends up asking, working, failed,
# done or idle. Nothing here is real.
tool=$(basename "$0")
case $tool in
  claude) [[ $1 == auth ]] && { echo '{"loggedIn":true,"authMethod":"claude.ai"}'; exit 0; } ;;
  ssh) host=$1; shift ;;
esac
scene=$1
cols=$(stty size 2>/dev/null | cut -d' ' -f2); cols=${cols:-100}
e=$'\e'
off="$e[0m" dim="$e[2m" bold="$e[1m" green="$e[32m" red="$e[31m" yellow="$e[33m" blue="$e[34m"
magenta="$e[35m" cyan="$e[36m" gray="$e[90m" orange="$e[38;5;209m" panel="$e[48;5;236m"

title() { printf '\e]0;%s\a' "$1"; }
wrap() { fold -s -w $((cols - 4)) | sed "1s/^/$1/; 2,\$s/^/  /"; }
rule() { local s=""; for ((i = 0; i < $1; i++)); do s+="─"; done; printf '%s' "$s"; }
stamp() { date -v-"$1"M +"%b %-d at %-I:%M %p"; }
# Prints `lines` (one per argument) a little apart, so the burst reads as work being done.
slowly() { for l; do printf '%s\n' "$l"; sleep "${gap:-0.03}"; done; }

# ── Codex ────────────────────────────────────────────────────────────────────────────────────────
cx_user() { printf '\n%s› %s%*s%s\n\n' "$panel" "$1" $((cols - ${#1} - 2)) '' "$off"; }
cx_step() { printf '%s•%s %s%s%s %s\n' "$green" "$off" "$bold" "$1" "$off" "$2"; shift 2
            local mark="└"; for l; do printf '  %s%s %s%s\n' "$dim" "$mark" "$l" "$off"; mark=" "; done; }
cx_say() { printf '%s\n\n' "$1" | wrap "• "; }
cx_idle() { # worked-for, minutes ago, folder, thread
  printf '%sWorked for %s • %s%s\n\n' "$dim" "$1" "$(stamp "$2")" "$off"
  printf '%s› %sAsk Codex to do anything%s%*s%s\n\n' "$panel" "$dim" "$off$panel" $((cols - 26)) '' "$off"
  printf '  %sgpt-6 xhigh%s %s·%s %s %s·%s %s%s%s\n  %s? for shortcuts%s' "$cyan" "$off" "$dim" "$off" "$3" "$dim" "$off" "$cyan" "$4" "$off" "$dim" "$off"
}
cx_working() { # what, seconds so far
  local t=$2 glyphs=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) i=0
  while :; do
    printf '\r\e[K%s%s%s %s%s%s (%dm %02ds • esc to interrupt)' "$cyan" "${glyphs[i % 10]}" "$off" "$bold" "$1" "$off" $((t / 60)) $((t % 60))
    sleep 0.5; i=$((i + 1)); ((i % 2)) || t=$((t + 1))
  done
}

# ── Claude Code ──────────────────────────────────────────────────────────────────────────────────
cc_user() { printf '\n%s> %s%s\n\n' "$gray" "$1" "$off"; }
cc_tool() { printf '%s⏺%s %s%s%s(%s)\n' "$green" "$off" "$bold" "$1" "$off" "$2"; shift 2
            local first=1; for l; do ((first)) && printf '  ⎿  %s\n' "$l" || printf '     %s\n' "$l"; first=0; done; }
cc_say() { printf '%s\n\n' "$1" | wrap "⏺ "; }
cc_box() {
  printf '%s╭%s╮%s\n' "$gray" "$(rule $((cols - 2)))" "$off"
  printf '%s│%s > %s%*s%s│%s\n' "$gray" "$off" "$1" $((cols - 5 - ${#1})) '' "$gray" "$off"
  printf '%s╰%s╯%s\n' "$gray" "$(rule $((cols - 2)))" "$off"
  printf '  %s⏵⏵ accept edits on (shift+tab to cycle)%s' "$dim" "$off"
}
cc_working() { # verb, seconds so far, tokens
  local t=$2 glyphs=(· ✢ ✳ ✶ ✻ ✽ ✻ ✶ ✳ ✢) i=0
  printf '\n\n'; cc_box ""
  while :; do
    printf '\e[5A\r\e[K%s%s %s…%s %s(%dm %02ds · ↓ %s tokens · esc to interrupt)%s\e[5B\r' \
      "$orange" "${glyphs[i % 10]}" "$1" "$off" "$dim" $((t / 60)) $((t % 60)) "$3" "$off"
    sleep 0.3; i=$((i + 1)); ((i % 3)) || t=$((t + 1))
  done
}

# ── omp ──────────────────────────────────────────────────────────────────────────────────────────
omp_status() { printf '%sπ omp%s %s·%s kestrel-route %s·%s %s %s·%s ctx %s' "$magenta" "$off" "$dim" "$off" "$dim" "$off" "$1" "$dim" "$off" "$2"; }
# Streams `lines` forever, a tool call at a time, with the status line kept along the bottom.
omp_stream() { # folder, context, lines…
  local dir=$1 ctx=$2; shift 2
  while :; do
    for l; do printf '\r\e[K%s\n' "$l"; omp_status "$dir" "$ctx"; sleep 0.6; done
  done
}

case $tool:$scene in
# Codex: finished a moment ago, unseen (done).
codex:prefill)
  title "Tune prefill chunk size | kestrel"
  cx_user "Prefill stalls decode for long prompts. Find a chunk size that keeps p99 inter-token latency under 40 ms."
  cx_step Explored "" "Read sched/batch.rs, sched/prefill.rs" "Search chunk_tokens in crates/"; sleep 0.8
  cx_step Ran "bench/itl.sh --chunk 512,1024,2048 --conc 16" "chunk 512   p50 21 ms  p99 33 ms  prefill 41k tok/s" \
    "chunk 1024  p50 22 ms  p99 38 ms  prefill 52k tok/s" "chunk 2048  p50 25 ms  p99 61 ms  prefill 58k tok/s"; sleep 0.8
  cx_step Edited "crates/sched/src/prefill.rs (+18 -6)"; sleep 0.8
  cx_say "1024 is the sweet spot: p99 ITL 38 ms at 16 concurrent, and prefill keeps 90% of the 2048 throughput. I made it the default and left --prefill-chunk to override it."
  cx_idle "6m 12s" 1 "~/src/ml/kestrel" "Tune prefill chunk size" ;;
# Codex: idle, finished hours ago.
codex:stream)
  title "Explore streaming tool calls | ml"
  cx_user "How should we stream partial tool calls to the web client without breaking the old SSE consumers?"
  cx_step Explored "" "Read gateway/stream.ts, web/src/chat/useStream.ts" "Search tool_call_delta"
  cx_say "Send tool calls as their own event type (event: tool_delta) next to the text deltas. Old consumers ignore unknown events, so nothing breaks, and the new client can render arguments as they arrive. I'd ship it behind a capability header first."
  cx_idle "3m 43s" 540 "~/src/ml" "Explore streaming tool calls" ;;
codex:evict)
  title "Fix KV cache eviction race | kestrel"
  cx_user "We sometimes free a KV block that a running sequence still references. Find it."
  cx_step Ran "cargo test -p kv-cache --features loom -- evict" "1 failed: evict_while_append (loom found an interleaving after 1,204 runs)"
  cx_step Edited "crates/kv-cache/src/pool.rs (+11 -4)"
  cx_step Ran "cargo test -p kv-cache --features loom" "test result: ok. 37 passed; 0 failed"
  cx_say "The refcount was dropped before the block left the LRU list, so an eviction could pick it between the two. Both now happen under the shard lock; loom passes on every interleaving."
  cx_idle "14m 2s" 820 "~/src/ml/kestrel" "Fix KV cache eviction race" ;;
codex:limits)
  title "Audit rate limiter config | orbit"
  cx_user "Check that every public route has a rate limit and that the limits match the pricing tiers."
  cx_step Explored "" "Read config/limits.yaml, src/routes/*.ts"
  cx_say "All 42 public routes are covered. Two don't match the tiers: /v1/embeddings allows 600/min on Free (tier says 300) and /v1/files has no burst cap. Patch is ready on audit/limits."
  cx_idle "4m 51s" 1260 "~/src/orbit" "Audit rate limiter config" ;;
codex:review)
  title "Review gateway PR | orbit"
  cx_user "Review the streaming gateway PR before I merge it."
  cx_step Explored "" "Read 14 changed files (+612 -148)"
  cx_step Ran "npm test -- stream" "Test Files  6 passed (6)  Tests  88 passed (88)"
  cx_say "Looks good to merge after two fixes: the SSE writer never flushes on client abort (leaks a socket per cancelled request), and tool_delta events skip the redaction filter. Both are small; I left inline comments."
  cx_idle "8m 30s" 95 "~/src/orbit" "Review gateway PR" ;;
# Codex: asking to run a command.
codex:rollout)
  title "Roll out gateway v4.19 | harbor"
  cx_user "Roll out gateway v4.19 to production, one region at a time, and watch error rates."
  cx_step Ran "kubectl -n prod rollout status deploy/orbit-gw --context eu-west" "deployment \"orbit-gw\" successfully rolled out"
  cx_step Ran "./scripts/errors.sh eu-west --since 10m" "5xx 0.03%  p95 182 ms  (baseline 0.04%, 190 ms)"
  printf '\n%sWould you like to run the following command?%s\n\n' "$bold" "$off"
  printf '  %s$ kubectl -n prod set image deploy/orbit-gw gw=orbit/gw:4.19.0 --context us-east%s\n\n' "$yellow" "$off"
  printf '%s› 1. Yes, proceed%s\n  2. Yes, and don'"'"'t ask again for this command\n  3. No, and tell Codex what to do differently %sesc%s\n' "$cyan" "$off" "$dim" "$off"
  read -r _ ;;
# Codex: working.
codex:moe)
  title "Port fused MoE kernel to GB10 | kestrel"
  cx_user "Port the fused MoE kernel to the GB10 build and get it within 5% of the Hopper numbers."
  cx_step Explored "" "Read kernels/moe/fused_moe.cu, kernels/moe/tune.json"
  cx_step Ran "nvcc -arch=sm_121a -O3 kernels/moe/fused_moe.cu -o build/moe" "ptxas info: Used 168 registers, 98304 bytes smem"
  cx_step Ran "bench/moe.sh --experts 128 --topk 8 --tokens 4096" "fused_moe   1.84 ms   312 TFLOP/s   (target 1.76 ms)"
  cx_say "Register pressure is the gap. Trying a 64x128 tile with a two-stage pipeline instead of three."
  cx_step Edited "kernels/moe/fused_moe.cu (+42 -17)"
  cx_working "Working" 187 ;;

# Claude Code: working.
claude:backfill)
  title "Speed up embedding backfill"
  cc_user "The embedding backfill for 40M documents will take 3 days. Make it finish overnight."
  cc_tool Read "jobs/backfill.py" "Read 214 lines"
  cc_tool Bash "python -m jobs.backfill --dry-run --limit 20000" "20,000 docs in 61.2 s · 327 docs/s · GPU util 38%"
  cc_say "The GPU sits idle while each batch is tokenized. I'll move tokenization to a worker pool and double-buffer batches onto the GPU."
  cc_tool Update "jobs/backfill.py" "Updated jobs/backfill.py with 46 additions and 19 removals"
  cc_tool Bash "python -m jobs.backfill --dry-run --limit 20000" "20,000 docs in 17.9 s · 1,117 docs/s · GPU util 91%"
  cc_say "3.4x faster: 40M docs now take about 10 hours. Running it on a 2M slice against the real index to check recall before the full run."
  cc_tool Bash "python -m jobs.backfill --slice 0:2000000 --verify-recall" "Running… 812,400 / 2,000,000"
  cc_working Backfilling 1287 "18.4k" ;;
# Claude Code: asking to make an edit.
claude:ttl)
  title "Unify session TTL"
  cc_user "Session TTL is set in three places and they disagree. Make one source of truth."
  cc_tool Search 'pattern: "SESSION_TTL|ttl_seconds"' "Found 3 files"
  cc_say "gateway uses 15 min, the web app 30 min and the worker 60 min. I'll read it from config/auth.ts everywhere; 30 min matches the docs."
  printf '%s╭%s╮%s\n' "$gray" "$(rule $((cols - 2)))" "$off"
  printf ' %sEdit file%s src/auth/session.ts\n' "$bold" "$off"
  printf '   %s12 -  const TTL = 15 * 60%s\n   %s12 +  const TTL = config.auth.sessionTtlSeconds%s\n\n' "$red" "$off" "$green" "$off"
  printf ' Do you want to make this edit to session.ts?\n %s❯ 1. Yes%s\n   2. Yes, allow all edits during this session (shift+tab)\n   3. No, and tell Claude what to do differently (esc)\n' "$cyan" "$off"
  printf '%s╰%s╯%s\n' "$gray" "$(rule $((cols - 2)))" "$off"
  read -r _ ;;
# Claude Code: finished a moment ago, unseen (done).
claude:migration)
  title "Write migration for usage table"
  cc_user "Add per-model token columns to usage_daily without locking the table."
  cc_tool Read "db/schema/usage_daily.sql" "Read 48 lines"; sleep 0.8
  cc_tool Write "db/migrations/0142_usage_tokens.sql" "Wrote 31 lines"; sleep 0.8
  cc_tool Bash "make migrate-check" "0142_usage_tokens: online-safe (ADD COLUMN … DEFAULT NULL, CREATE INDEX CONCURRENTLY)" \
    "dry run on staging snapshot: 2.1 s, no exclusive locks"; sleep 0.8
  cc_say "Done. The columns are nullable so the ALTER is instant, the index builds concurrently, and a backfill job fills old rows in 10k batches. Ready for review."
  cc_box "" ;;

# omp: working.
omp:drift)
  title "π > Locate tokenizer drift"
  printf ' %s●%s bash  rg -n "merge_ranks" crates/tok/\n   crates/tok/src/bpe.rs:211: fn merge_ranks(&self, pair: (u32, u32))\n\n' "$magenta" "$off"
  printf ' recap: eval and serving tokenize "naïve café" differently. Serving normalizes to NFC\n before BPE; the eval harness does not. 0.4%% of eval prompts are affected.\n\n'
  omp_stream "~/src/ml" "41%" \
    " $magenta●$off bash  python eval/tok_diff.py --set mmlu --limit 2000" \
    "   checked 2000 prompts · 9 differ · all contain combining marks" \
    " $magenta●$off read  eval/harness/tokenize.py" \
    " $magenta●$off edit  eval/harness/tokenize.py  +3 -1  (normalize NFC before encode)" \
    " $magenta●$off bash  python eval/tok_diff.py --set all" \
    "   checked 48,210 prompts · 0 differ" \
    " recap: fixed in the harness; re-running the three affected evals." ;;
omp:accept)
  title "π > Benchmark draft acceptance"
  printf ' recap: the draft model accepts 3.1 tokens per step on chat, 2.2 on code.\n Trying a code-tuned draft head.\n\n'
  omp_stream "~/src/ml/kestrel" "63%" \
    " $magenta●$off bash  bench/spec.sh --draft head-code-v2 --set humaneval" \
    "   step 120/400  accepted/step 2.71  tok/s 1,384" \
    "   step 240/400  accepted/step 2.74  tok/s 1,401" \
    "   step 400/400  accepted/step 2.76  tok/s 1,409  (+25% vs head-v1)" \
    " $magenta●$off bash  bench/spec.sh --draft head-code-v2 --set chat-mix" \
    "   step 200/400  accepted/step 3.02  tok/s 1,512" \
    " recap: code improves without hurting chat (3.02 vs 3.1). Checking long-context next." ;;

# grok: idle.
grok:thread)
  title "Draft launch thread - grok"
  printf '%sHere is a five-post thread for the launch:%s\n\n' "$bold" "$off"
  printf '1/ Kestrel 2.0 is out: speculative decoding on by default, 1.9x faster chat on the same GPUs.\n\n2/ The draft model now adapts per request: code, chat and long documents each get their own head.\n\n3/ Prefill no longer stalls decoding: p99 time between tokens stays under 40 ms at 16 users.\n\n4/ Everything is open source, with benchmarks you can run yourself.\n\n5/ Try it: pip install kestrel\n\n'
  printf '%s>%s █\n\n%sEnter:send  Opt+Enter:newline  Shift+Tab:mode  Ctrl+C:quit%s' "$cyan" "$off" "$dim" "$off" ;;

# ssh: a model server's log, and a training run.
ssh:serve)
  title "admin@$host: ~"
  printf 'Welcome to Ubuntu 24.04.3 LTS (GNU/Linux 6.11.0-1016-nvidia aarch64)\n\nLast login: %s\n' "$(date -v-2H '+%a %b %e %H:%M:%S %Y')"
  printf '%sadmin@%s%s:~$ docker logs -f --tail 5 kestrel\n' "$green" "$host" "$off"
  while :; do
    printf '%sINFO%s %s engine: %d running · %d waiting · prefill %4.1fk tok/s · decode %4d tok/s · KV %d%%\n' "$green" "$off" "$(date +%H:%M:%S)" \
      $((RANDOM % 6 + 10)) $((RANDOM % 4)) "$((RANDOM % 90 + 140))e-1" $((RANDOM % 300 + 1100)) $((RANDOM % 9 + 84))
    sleep 0.8
    printf '%sINFO%s %s POST /v1/chat/completions 200 · %d ms · %d tok\n' "$green" "$off" "$(date +%H:%M:%S)" $((RANDOM % 900 + 300)) $((RANDOM % 700 + 80))
    sleep 0.7
  done ;;
ssh:smi)
  title "admin@$host: ~"
  while :; do
    printf '\e[H\e[2J%sadmin@%s%s:~$ watch -n 2 nvidia-smi\n\n' "$green" "$host" "$off"
    printf '+-----------------------------------------------------------------------------------------+\n'
    printf '| NVIDIA-SMI 580.95.05              Driver Version: 580.95.05      CUDA Version: 13.0     |\n'
    printf '|-----------------------------------------+------------------------+----------------------+\n'
    printf '| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |\n'
    printf '| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |\n'
    printf '|=========================================+========================+======================|\n'
    printf '|   0  NVIDIA GB10                    On  |   0000000F:01:00.0 Off |                  N/A |\n'
    printf '| N/A   %2dC    P0             %2dW /  N/A  | Not Supported          |     %2d%%      Default |\n' $((RANDOM % 4 + 64)) $((RANDOM % 6 + 38)) $((RANDOM % 9 + 59))
    printf '+-----------------------------------------+------------------------+----------------------+\n\n'
    printf '+-----------------------------------------------------------------------------------------+\n'
    printf '| Processes:                                                                              |\n'
    printf '|  GPU   GI   CI              PID   Type   Process name                        GPU Memory |\n'
    printf '|=========================================================================================|\n'
    printf '|    0   N/A  N/A           48211      C   kestrel-serve                         61204MiB |\n'
    printf '|    0   N/A  N/A           51877      C   sonata-server                          8312MiB |\n'
    printf '+-----------------------------------------------------------------------------------------+\n'
    sleep 2
  done ;;
ssh:train)
  title "admin@$host: ~/runs/draft-v3"
  printf '%sadmin@%s%s:~/runs/draft-v3$ tail -f train.log\n' "$green" "$host" "$off"
  step=41200 loss=1900
  while :; do
    step=$((step + 10)); loss=$((loss - RANDOM % 3))
    printf 'step %d | loss %d.%03d | lr 2.1e-4 | %d.%d it/s | gpu %d%% | %d tok/s\n' $step $((loss / 1000)) $((loss % 1000)) 1 $((RANDOM % 3 + 7)) $((RANDOM % 4 + 95)) $((RANDOM % 900 + 21000))
    sleep 0.9
  done ;;

# npm: the integration tests fail.
npm:test)
  title "npm test"
  printf '\n> orbit@4.19.0 test\n> vitest run tests/integration\n\n'
  gap=0.3 slowly " ${green}✓${off} tests/integration/auth.test.ts (12)" " ${green}✓${off} tests/integration/billing.test.ts (31)" \
    " ${green}✓${off} tests/integration/stream.test.ts (18)" " ${red}❯${off} tests/integration/limits.test.ts (9) 1 failed"
  printf '\n %sFAIL%s  limits > embeddings: free tier gets 300/min\n %sAssertionError: expected 600 to be 300%s\n   ❯ tests/integration/limits.test.ts:48:31\n\n' "$red" "$off" "$red" "$off"
  printf ' Test Files  %s1 failed%s | 3 passed (4)\n      Tests  %s1 failed%s | 69 passed (70)\n' "$red" "$off" "$red" "$off"
  sleep 1; exit 1 ;;

# As `agent`: the tiles of the simpler board.
*:ask)
  title "$2"
  cc_tool Read "src/auth/session.ts" "Read 212 lines"
  cc_tool Read "src/auth/refresh.ts" "Read 98 lines"
  cc_say "The session TTL is set in two places and they disagree (15 min vs 30 min). I'll move it to config/auth.ts and read it from both."
  printf '%sDo you want to make this edit to src/auth/session.ts? (y/n)%s ' "$bold" "$off"
  read -r _ ;;
*:work)
  title "$2"; i=1
  while :; do printf '%s[build]%s compiling module %d of 480 ... %sok%s\n' "$dim" "$off" "$i" "$green" "$off"; i=$((i % 480 + 1)); sleep 0.2; done ;;
*:fail)
  title "$2"
  cc_tool Bash "npm test" "PASS  tests/cart.test.ts" "PASS  tests/pricing.test.ts" "${red}FAIL${off}  tests/tax.test.ts"
  printf '   ✕ applies VAT to digital goods (14 ms)\n     Expected: 120.00\n     Received: 100.00\n\nTests: %s1 failed%s, 41 passed, 42 total\n' "$red" "$off"
  sleep 1; exit 1 ;;
*:done)
  title "$2"
  for f in parser lexer resolver emitter optimizer linker; do
    printf '%s[test]%s %-10s %s✓%s %d passed\n' "$dim" "$off" "$f" "$green" "$off" $((RANDOM % 30 + 5)); sleep 0.45
  done
  printf '\n%s%sAll 132 tests passed%s in 3.1s\n' "$green" "$bold" "$off" ;;
*:logs)
  title "$2"
  while :; do printf '%s%s%s GET /api/v2/orders %s200%s %dms\n' "$dim" "$(date +%H:%M:%S)" "$off" "$green" "$off" $((RANDOM % 80 + 12)); sleep 1.5; done ;;
esac
# Idle or done: stay open, as the real tool would, waiting for the next message.
while :; do sleep 3600; done
