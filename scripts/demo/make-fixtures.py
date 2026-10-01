#!/usr/bin/env python3
"""Writes a made-up home folder for the README screenshot: Claude and Codex desktop conversations
(their transcripts and the app metadata Tessera reads), Codex plan limits, and project folders.
Nothing here is real. Usage: make-fixtures.py <home>"""
import json, os, sys, uuid
from datetime import datetime, timedelta, timezone

home = sys.argv[1]
now = datetime.now(timezone.utc)


def at(seconds_ago):
    return (now - timedelta(seconds=seconds_ago)).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def write(path, lines):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("\n".join(json.dumps(l, separators=(",", ":")) for l in lines) + "\n")


for project in ["api", "web", "infra", "mobile", "docs"]:
    os.makedirs(os.path.join(home, "code", project), exist_ok=True)

# Claude desktop conversations: (title, folder, turns, how it ends)
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

for title, folder, turns, quiet in claude:
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
    write(os.path.join(home, ".claude/projects/-demo-" + folder, cli + ".jsonl"), lines)
    meta = {"sessionId": "local_" + local, "cliSessionId": cli, "cwd": os.path.join(home, "code", folder), "title": title,
            "lastActivityAt": int((now - timedelta(seconds=quiet)).timestamp() * 1000), "isArchived": False}
    path = os.path.join(home, "Library/Application Support/Claude/claude-code-sessions", str(uuid.uuid4()), str(uuid.uuid4()), "local_" + local + ".json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump(meta, open(path, "w"))

# Codex desktop threads: (name, folder, items, still working)
codex = [
    ("Migrate billing tables to Postgres 17", "infra", [
        ("user", "Plan and run the migration of the billing tables to Postgres 17 with zero downtime."),
        ("call", "exec_command", {"cmd": "pg_dump --schema-only billing > schema.sql"}),
        ("assistant", "Schema exported. Creating the logical replication slot and copying the 4 billing tables."),
        ("call", "exec_command", {"cmd": "psql -f migrate/003_replicate_billing.sql"}),
    ], True),
    ("Profile the image resize worker", "api", [
        ("user", "The resize worker's p95 doubled this week. Profile it."),
        ("call", "exec_command", {"cmd": "go test -bench Resize -cpuprofile cpu.out ./worker"}),
        ("assistant", "92% of the time is in re-decoding the source per size. Decoding once and resizing from memory cuts p95 from 840 ms to 310 ms."),
    ], False),
]

index = []
for name, folder, items, working in codex:
    tid = str(uuid.uuid4())
    t = 300 + 60 * len(items) if not working else 30 + 20 * len(items)
    lines = [{"timestamp": at(t + 5), "type": "session_meta", "payload": {"id": tid, "cwd": os.path.join(home, "code", folder), "originator": "Codex Desktop", "timestamp": at(t + 5)}},
             {"timestamp": at(t + 4), "type": "turn_context", "payload": {"model": "gpt-6", "cwd": os.path.join(home, "code", folder)}},
             {"timestamp": at(t + 3), "type": "event_msg", "payload": {"type": "task_started", "turn_id": "t1"}}]
    for kind, a, *b in items:
        t -= 20 if working else 60
        if kind in ("user", "assistant"):
            lines.append({"timestamp": at(t), "type": "response_item", "payload": {"type": "message", "role": kind,
                          "content": [{"type": "input_text" if kind == "user" else "output_text", "text": a}]}})
        else:
            lines.append({"timestamp": at(t), "type": "response_item", "payload": {"type": "function_call", "name": a, "arguments": json.dumps(b[0]), "call_id": "c" + uuid.uuid4().hex[:8]}})
    if not working:
        lines.append({"timestamp": at(t - 5), "type": "event_msg", "payload": {"type": "task_complete", "turn_id": "t1"}})
    lines.append({"timestamp": at(max(t - 6, 1)), "type": "event_msg", "payload": {"type": "token_count", "rate_limits": {
        "primary": {"used_percent": 34, "window_minutes": 300, "resets_in_seconds": 7400},
        "secondary": {"used_percent": 22, "window_minutes": 10080, "resets_in_seconds": 300000}, "plan_type": "pro"}}})
    day = datetime.now().strftime("%Y/%m/%d")  # Codex files sessions under the local date
    write(os.path.join(home, ".codex/sessions", day, "rollout-" + now.strftime("%Y-%m-%dT%H-%M-%S") + "-" + tid + ".jsonl"), lines)
    index.append({"id": tid, "thread_name": name})
write(os.path.join(home, ".codex/session_index.jsonl"), index)
print(home)
