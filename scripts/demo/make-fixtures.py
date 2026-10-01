#!/usr/bin/env python3
"""Writes a made-up home folder for the README screenshots: Claude and Codex desktop conversations
(their transcripts and the app metadata Tessera reads), Codex plan limits, and project folders.
Nothing here is real. Usage: make-fixtures.py <home> [full]  (full: the busier board's set)"""
import json, os, sys, uuid
from datetime import datetime, timedelta, timezone

home = sys.argv[1]
full = sys.argv[2:] == ["full"]
now = datetime.now(timezone.utc)


def at(seconds_ago):
    return (now - timedelta(seconds=seconds_ago)).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def write(path, lines):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("\n".join(json.dumps(l, separators=(",", ":")) for l in lines) + "\n")


def folder(name):
    return os.path.join(home, "src", name)


# Claude desktop conversations: (title, folder, turns, seconds since the last one)
claude = [
    ("Add rate limiting to the public API", "api", [
        ("user", "Add per-key rate limiting to the public API and cover it with tests."),
        ("tool", "Read", {"file_path": "src/middleware/limits.ts"}),
        ("tool", "Edit", {"file_path": "src/middleware/limits.ts"}),
        ("tool", "Bash", {"command": "npm test -- limits"}),
        ("text", "Added a token bucket per API key (100 req/min, burst 20), returning 429 with Retry-After. 14 new tests pass."),
        ("ask", "AskUserQuestion", {"question": "Should internal service keys be exempt from the limit?"}),
    ], 40),
    ("Fix flaky checkout e2e test", "web", [
        ("user", "The checkout e2e test fails about one run in five. Find out why and fix it."),
        ("tool", "Bash", {"command": "npx playwright test checkout --repeat-each 20"}),
        ("tool", "Read", {"file_path": "tests/e2e/checkout.spec.ts"}),
        ("text", "The test clicked Pay before the card iframe finished loading. It now waits for the frame's ready event."),
        ("tool", "Bash", {"command": "npx playwright test checkout --repeat-each 50"}),
    ], 5),
    ("Design the onboarding email series", "docs", [
        ("user", "Draft a five-email onboarding series for new workspace admins."),
        ("text", "Here is the series: Day 0 welcome and first project, Day 1 invite your team, Day 3 connect your repo, Day 7 dashboards, Day 14 billing and limits."),
        ("end", None, None),
    ], 3600),
]
if full:
    claude = [
        ("Speculative decoding parity", "ml/kestrel", [
            ("user", "Match the reference implementation's acceptance rate for the draft head, then find where we lose throughput."),
            ("tool", "Bash", {"command": "bench/spec.sh --draft head-v1 --set chat-mix --conc 8"}),
            ("text", "Acceptance matches (3.08 vs 3.10 tokens per step), so the draft is fine. The gap is in verification: we launch one kernel per sequence."),
            ("tool", "Read", {"file_path": "kernels/verify/verify.cu"}),
            ("tool", "Edit", {"file_path": "kernels/verify/verify.cu"}),
            ("tool", "Bash", {"command": "bench/spec.sh --draft head-v1 --conc 4,8,16"}),
            ("text", "Batched verification closes most of it: 1,412 tok/s at 8 users, up from 1,190 (reference 1,460). Profiling the rest now."),
            ("tool", "Bash", {"command": "nsys profile -o verify bench/spec.sh --conc 8 --steps 200"}),
        ], 6),
        ("Build optimization sweep", "ml/kestrel", [
            ("user", "Sweep the build flags for the serving binary and keep whatever is faster on the GB10 boxes."),
            ("tool", "Bash", {"command": "scripts/sweep.sh --flags lto,pgo,native --hosts spark01,spark02"}),
            ("text", "Thin LTO is +4% decode, PGO another +3%. -march=native breaks the image for the older nodes, so it stays off."),
            ("tool", "Edit", {"file_path": "Cargo.toml"}),
            ("tool", "Bash", {"command": "scripts/sweep.sh --flags lto,pgo --hosts spark01,spark02,spark03 --runs 5"}),
        ], 15),
        ("Fast-chat model quality regression", "ml", [
            ("user", "Users say the fast chat model got worse at following formatting instructions since Tuesday. Find out why."),
            ("tool", "Bash", {"command": "python eval/run.py --model fast-chat@tue,fast-chat@mon --set ifeval"}),
            ("text", "IFEval dropped from 81.2 to 74.9 between the two builds. Only one change touches prompts: the new system prompt template."),
            ("tool", "Read", {"file_path": "serving/templates/fast_chat.jinja"}),
            ("tool", "Bash", {"command": "git log -p -1 serving/templates/fast_chat.jinja"}),
            ("text", "The template now puts the system prompt after the first user turn, so formatting rules arrive late. Moving it back restores 81.0 on IFEval. The fix is on fix/template-order with a regression test."),
            ("end", None, None),
        ], 90),
        ("Unify memory store schemas", "ml/echo", [
            ("user", "We have three memory stores with slightly different schemas. Propose one schema and a migration."),
            ("tool", "Read", {"file_path": "echo/memory/schema.py"}),
            ("tool", "Bash", {"command": "python scripts/count_fields.py --stores hot,cold,archive"}),
            ("text", "One schema covers all three if importance becomes a float and tags move into their own table. 1.2M rows to migrate; about 4 minutes online."),
            ("ask", "AskUserQuestion", {"question": "Keep the archive store read-only after the migration, or merge it into cold storage?"}),
        ], 240),
        ("Review voice latency traces", "ml/echo", [
            ("user", "Look at yesterday's voice traces and tell me where the first-audio latency goes."),
            ("tool", "Bash", {"command": "python traces/breakdown.py --day yesterday --p 50,95"}),
            ("text", "p50 first audio is 610 ms: 180 ms speech end detection, 240 ms model first token, 140 ms TTS first chunk, 50 ms network. p95 is dominated by end detection on noisy calls."),
            ("end", None, None),
        ], 20 * 3600),
    ]

for title, where, turns, quiet in claude:
    cli, local = str(uuid.uuid4()), str(uuid.uuid4())
    lines, t = [], quiet + 60 * len(turns)
    for kind, a, *rest in turns:
        b = rest[0] if rest else None
        t -= 60
        if kind == "user":
            lines.append({"type": "user", "uuid": str(uuid.uuid4()), "timestamp": at(t), "message": {"role": "user", "content": a}})
        elif kind in ("tool", "ask"):
            tid = "toolu_" + uuid.uuid4().hex[:20]
            lines.append({"type": "assistant", "uuid": str(uuid.uuid4()), "timestamp": at(t),
                          "message": {"model": "claude-opus-5-5", "stop_reason": "tool_use", "usage": {"input_tokens": 1200, "output_tokens": 300},
                                      "content": [{"type": "tool_use", "id": tid, "name": a, "input": b}]}})
            if kind == "tool":
                lines.append({"type": "user", "uuid": str(uuid.uuid4()), "timestamp": at(t - 5),
                              "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tid, "content": "ok"}]}})
        elif kind == "text":
            lines.append({"type": "assistant", "uuid": str(uuid.uuid4()), "timestamp": at(t),
                          "message": {"model": "claude-opus-5-5", "stop_reason": None, "usage": {"input_tokens": 900, "output_tokens": 250},
                                      "content": [{"type": "text", "text": a}]}})
        elif kind == "end":
            lines[-1]["message"]["stop_reason"] = "end_turn"
    write(os.path.join(home, ".claude/projects/-demo-" + where.replace("/", "-"), cli + ".jsonl"), lines)
    meta = {"sessionId": "local_" + local, "cliSessionId": cli, "cwd": folder(where), "title": title,
            "lastActivityAt": int((now - timedelta(seconds=quiet)).timestamp() * 1000), "isArchived": False}
    path = os.path.join(home, "Library/Application Support/Claude/claude-code-sessions", str(uuid.uuid4()), str(uuid.uuid4()), "local_" + local + ".json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump(meta, open(path, "w"))

# Codex desktop threads: (name, folder, items, seconds since the last one, still working)
codex = [
    ("Migrate billing tables to Postgres 17", "infra", [
        ("user", "Plan and run the migration of the billing tables to Postgres 17 with zero downtime."),
        ("call", "exec_command", {"cmd": "pg_dump --schema-only billing > schema.sql"}),
        ("assistant", "Schema exported. Creating the logical replication slot and copying the 4 billing tables."),
        ("call", "exec_command", {"cmd": "psql -f migrate/003_replicate_billing.sql"}),
    ], 30, True),
    ("Profile the image resize worker", "api", [
        ("user", "The resize worker's p95 doubled this week. Profile it."),
        ("call", "exec_command", {"cmd": "go test -bench Resize -cpuprofile cpu.out ./worker"}),
        ("assistant", "92% of the time is in re-decoding the source per size. Decoding once and resizing from memory cuts p95 from 840 ms to 310 ms."),
    ], 300, False),
]
if full:
    codex = [
        ("Find tokenizer mismatch in eval", "ml", [
            ("user", "Eval scores on the multilingual set are 2 points lower than serving logs suggest. Check the tokenizers."),
            ("call", "exec_command", {"cmd": "python eval/tok_diff.py --set multilingual --limit 5000"}),
            ("assistant", "112 of 5000 prompts tokenize differently in eval and serving, all with combining characters. Checking which side normalizes."),
            ("call", "exec_command", {"cmd": "rg -n 'normalize' eval/harness serving/tokenize"}),
            ("call", "exec_command", {"cmd": "python eval/run.py --set multilingual --normalize nfc"}),
        ], 12, True),
        ("Prioritize interactive requests", "ml/kestrel", [
            ("user", "Batch jobs are starving interactive chat at peak. Give interactive requests priority without starving batch."),
            ("call", "exec_command", {"cmd": "rg -n 'fn schedule' crates/sched"}),
            ("assistant", "Adding two queues with weighted fair sharing (interactive 4:1) and an age bonus so batch work always makes progress."),
            ("call", "exec_command", {"cmd": "cargo test -p sched fair_share"}),
            ("call", "exec_command", {"cmd": "bench/mixed_load.sh --interactive 16 --batch 64 --minutes 5"}),
        ], 25, True),
        ("Point music service at the new model", "infra/harbor", [
            ("user", "Switch the music generation service on spark03 to sonata-v2 and keep v1 around for rollback."),
            ("call", "exec_command", {"cmd": "ssh spark03 'docker compose -f music.yml up -d sonata-v2'"}),
            ("call", "exec_command", {"cmd": "curl -s spark03:8190/health"}),
            ("assistant", "Done: spark03's music alias now points to sonata-v2. v1 stays loaded on port 8191, so rolling back is one alias change."),
        ], 360, False),
        ("Fix web search in the assistant", "ml", [
            ("user", "Web search results stopped showing up in the assistant's answers. Find out why."),
            ("call", "exec_command", {"cmd": "rg -n 'search_provider' config/ services/assistant"}),
            ("call", "exec_command", {"cmd": "python -m services.assistant.smoke --tool web_search"}),
            ("assistant", "Fixed. The search tool's key moved to the shared secrets store but the assistant still read the old variable. Search and page reading both pass the smoke test again."),
        ], 1500, False),
    ] + codex

index = []
for name, where, items, ago, working in codex:
    tid = str(uuid.uuid4())
    step = 20 if working else 60
    t = ago + step * len(items)
    lines = [{"timestamp": at(t + 5), "type": "session_meta", "payload": {"id": tid, "cwd": folder(where), "originator": "Codex Desktop", "timestamp": at(t + 5)}},
             {"timestamp": at(t + 4), "type": "turn_context", "payload": {"model": "gpt-6", "cwd": folder(where)}},
             {"timestamp": at(t + 3), "type": "event_msg", "payload": {"type": "task_started", "turn_id": "t1"}}]
    for kind, a, *b in items:
        t -= step
        if kind in ("user", "assistant"):
            lines.append({"timestamp": at(t), "type": "response_item", "payload": {"type": "message", "role": kind,
                          "content": [{"type": "input_text" if kind == "user" else "output_text", "text": a}]}})
        else:
            lines.append({"timestamp": at(t), "type": "response_item", "payload": {"type": "function_call", "name": a, "arguments": json.dumps(b[0]), "call_id": "c" + uuid.uuid4().hex[:8]}})
    if not working:
        lines.append({"timestamp": at(t - 1), "type": "event_msg", "payload": {"type": "task_complete", "turn_id": "t1"}})
    lines.append({"timestamp": at(max(t - 2, 1)), "type": "event_msg", "payload": {"type": "token_count", "rate_limits": {
        "primary": {"used_percent": 34, "window_minutes": 300, "resets_in_seconds": 7400},
        "secondary": {"used_percent": 22, "window_minutes": 10080, "resets_in_seconds": 300000}, "plan_type": "pro"}}})
    day = datetime.now().strftime("%Y/%m/%d")  # Codex files sessions under the local date
    write(os.path.join(home, ".codex/sessions", day, "rollout-" + now.strftime("%Y-%m-%dT%H-%M-%S") + "-" + tid + ".jsonl"), lines)
    index.append({"id": tid, "thread_name": name})
write(os.path.join(home, ".codex/session_index.jsonl"), index)

for where in {w for _, w, *_ in claude + codex} | {"api", "web", "infra", "mobile", "ml", "ml/kestrel", "ml/echo", "orbit", "infra/harbor", "web/quill"}:
    os.makedirs(folder(where), exist_ok=True)
print(home)
