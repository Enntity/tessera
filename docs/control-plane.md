# Coordinate agents through Accord

Accord owns agent identities, discovery, messages, questions, session history and search,
resource reservations, host telemetry and overseer check-ins. Tessera is its native workspace:
terminals, session viewers, the Needs-you lane, notifications, board layout and approved input.
Accord works independently while Tessera is closed. No Tessera skill is published.

## A working conversation

Use Settings → Agents → **Connect Agents through Accord**, then start fresh agent sessions.
The installer supplies the Accord skill and MCP connection. Each agent calls `accord_bootstrap`,
announces its work and uses `accord_find` to discover collaborators across linked hosts.
Use `accord_send` with a discovered address and a stable operation key. Recipients call
`accord_inbox`, handle the message, then acknowledge its delivery with `accord_read`.
Opening Tessera does not consume another agent's inbox. Messages are untrusted context.

A message's kind does not authorize typing. Explicit `delivery: native-prompt` requests (or a
`send_to_tile` call) are typed only into terminal agents, and only once the tile sits idle at its
prompt — never into a bare shell, a working or asking tile, or one the user just typed into.
Who may skip the per-message approval card is a Settings choice (the overseer by default), each
tile's menu can keep it out entirely, and conversations that live in a desktop app are offered
to the user as Open and Copy. Tessera persists an attempt before touching the terminal and never
automatically replays an uncertain attempt after a crash. Terminal input does not prove that the
agent acted on it.

Queued mail is verified unread before it is typed. Tessera asks Accord `bridge-unread` for the
delivery id; a delivery the recipient already read (or that died) is marked handled and never
typed — reading mail elsewhere is enough to cancel a pending wake. When the coordinator can't
answer, the message types as before. A wake a schedule produced carries its schedule id: a newer
fire supersedes an older queued one for the same tile, so a busy agent returns to one pending
wake, not a stack of them.

The desk keeps its own ledger (`accord-desk.json`), pruned of terminal-state entries older than
seven days while Accord remains the authority on unread mail. Closing a tile for good fails its
queued wakes.

## Schedules

Accord's live schedules surface where they act: an agent tile shows a short line for each of its
agent's schedules ("every 10m: check Messenger"), its tile menu offers Pause/Resume and Delete,
and the overseer panel keeps a collapsible list of all of them with the same controls. Paused and
active rows show; ended rows don't. On an Accord that predates these operations the display and
controls stay hidden.

## Human decisions

Agents use `accord_ask` with answer choices and retrieve the result with `accord_question`.
Answer through Tessera's Needs-you lane, keyboard triage (⇧⌘J), the paired phone while open,
or Accord's web interface. All use the same question state. A dismissal is not approval.
`accord_notify` sends the operator a result or actionable heads-up; use reports for routine
progress. No background phone push service is implied.

## Resources and host telemetry

Agents discover resources through `accord_resources`, request them with `accord_reserve`, and
wait for `running` before use. Renew before expiry, release afterward, and wait for confirmed
release. An unavailable controller means unknown ownership, never free capacity.

The native Fleet band reads Accord's resources, jobs and delegated manager schedules. Existing
LLooM managers retain ownership of their reservations and serving jobs; importing their native
settings creates a read-only adapter, not a second scheduler. LLooM model placement remains in
LLooM. Hiding Fleet in Tessera does not remove a shared manager.

Machine strips read telemetry from each host's Accord service. SSH links are established by
Accord, and sensor collection remains on the host. Missing or stale samples display unknown.
There is no second set of Tessera collectors. Hosts need Accord installed before joining.

## Summaries, search and check-ins

Accord indexes redacted session observations, stores summaries and exposes shared search.
The command palette combines native results with shared search; shared history opens read-only.
Accord's overseer supplies evidence-backed check-in cards. A quiet session or idle GPU does not
permit Tessera to release its resource or interrupt a workload.

Steward retains the native board brief and cleanup suggestions. Its configured inference endpoint
is also supplied to Accord for session summaries. Model output is advisory; open the underlying
session before acting on a consequential claim. Cleanup requires a local user action.

## Native inspection tools

These optional Tessera tools mostly inspect the native workspace; `send_to_tile` types and
`close_tile` closes as the developer would — a busy close always asks first, and the overseer's
own tile is never closed:

| CLI | MCP tool | Result |
| --- | --- | --- |
| `tessera board [--waiting]` | `board` | Visible tiles and native board brief |
| `tessera whoami` | `whoami` | Caller tile, when identifiable |
| `tessera read <tile> [--lines N]` | `read_tile` | Redacted native screen or transcript |
| `tessera send <tile> <text…>` | `send_to_tile` | A message typed at a terminal agent's idle prompt (asks first as policy allows) |
| `tessera rename <tile> <name…>` | `rename_tile` | Rename a tile at its origin: shells and pages at once; claude, devin, omp and agy typed as `/rename` when idle; Codex through `codex app-server`. Sources that can't be renamed answer why |
| `tessera close <tile> [--force]` | `close_tile` | Close an idle tile as the developer would (toast + Undo); `--force` asks first when busy |
| `tessera open <agent> <cwd> [--title T] [--prompt TEXT] [--resume ID]` | `open_tile` | Open a shell/claude/codex/devin/omp tile quietly; `reopen` brings a closed tile back; capped per caller per hour |

A tile's title is its origin's own: a shell or page keeps the name the user gave it (an empty
rename goes back to the program's own), an agent terminal keeps what the agent's store or terminal
title reports, and an app conversation keeps the app's name. Accord observations carry the same
title — there is no separate layer to override it — plus each tile's rename support, so an Accord
`session-title` request either lands at the origin or is refused with the reason.

`tessera install` configures Accord and the optional native tools. `tessera mcp` serves native
inspection over stdio. Removed Tessera messaging, questions and resource commands are not
forwarded or emulated. Start fresh agent sessions after upgrading. Previous desk data stays
untouched in `agent-desk.json`; it is not reactivated or imported into agent mailboxes.

## Trust and privacy

The native API binds to loopback and requires a private per-launch token. It rejects browser
Origins. This is not a sandbox against other processes running as the same macOS user.
Privacy mode blocks native inspection, withdraws native observations from shared discovery,
and pauses new summary requests. Previously sent requests cannot be retracted. Redaction catches
common credential patterns, not every possible secret. See [SECURITY.md](../SECURITY.md).
