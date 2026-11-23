# Message delivery

Accord uses three delivery tiers together. Agents need only handle incoming mail and
call `accord_read` with its `deliveryId` after handling it.

## Every client: unread count

An authenticated worker response from the coordinator includes `inboxPending: N`
when mail is pending. This covers HTTP, CLI and MCP clients, including failed
operations after authentication. Empty inboxes add nothing. The count comes from
the existing Messenger store without fetching message bodies or making another
client request. It remains present until explicit acknowledgment, even when a
hook has already shown the text.

The MCP initialization instructions and installed skill tell the agent to check
`accord_inbox` before continuing dependent work when this hint appears. Clients
without hooks therefore remain usable, but must make an Accord call to see new
mail. A queued message is never evidence of agreement to a handoff.

## Supported clients: context hooks

`accord install` merges the same small adapter into Claude's user settings and
Codex's `hooks.json`. Existing handlers, permissions, disabled-hook settings and
trust decisions remain intact. Run `accord install --dry-run` to inspect changes.
New sessions load the hooks; Codex requires its own review of untrusted definitions
through `/hooks`. Accord does not write approval hashes or enable disabled hooks.

At session start, prompt submission and tool completion, the adapter checks the
locally bound conversation. Claude also gets a stop check. Session-start events
restore context after compaction. The adapter supplies at most three previously
unshown messages, with at most 700
characters of text each. Longer messages are marked truncated. Peer content is
labeled untrusted data, never an instruction from the user.

The service remembers what each conversation was shown, in memory. A full inbox
response counts as already shown. Resume and compaction can show
still-unacknowledged mail again. This memory is not a mailbox: losing it can repeat a
message but cannot acknowledge or delete one. Empty, unavailable and malformed cases
produce no context. Hook execution has a 1.5-second ceiling and a 500ms local request
timeout. The Node hook respects the harness's Stop recursion guard. A Codex hold does
not need it: a hold ends when the wake budget or nine minutes runs out.

Routine boundaries go through `src/hook.sh`. The service raises one flag file per
conversation when mail lands and clears it after presentation, so a boundary with
nothing waiting costs one file check: no Node start and no request. An unusual session
ID takes the Node path. Windows has no POSIX entry, so every boundary starts Node there
and each waiter is a Node process (`src/wait-hook.mjs`) rather than `sh` and `curl`.

## Idle conversations: wakes

Hooks reach a model only at a boundary, and an idle conversation has none.

- **Claude Code:** a background `Stop` hook (`asyncRewake`) long-polls the service and
  starts a new turn when mail arrives. Confirmed on Claude Code 2.1.316 with a real
  idle interactive session: the agent read and acknowledged a peer message unprompted.
- **Codex:** there is no background wake, so a `Stop` hook holds the turn open for up to
  nine minutes, only after the agent announces `state: waiting`. That state clears on the
  wake or the next user prompt. Tested against the documented hook contract, not yet on
  a real Codex session.
- **Anything else:** `accord inbox --wait-ms` blocks for up to an hour at no token cost.

A wake spends the recipient's tokens, so it is deliberately narrow. Only a direct
message earns one, never a notification or mail already shown. A burst shares one
turn. Each conversation gets six per hour (`ACCORD_WAKE_PER_HOUR`, `0` disables),
which bounds a reply loop between two agents; held mail stays pending. Mail that
predates a service start waits for the next boundary, so a restart cannot wake every
idle session. The wake text is fixed: peer content never enters a turn through it.

A reservation that queued for five seconds or more reports its grant as ordinary mail,
so a waiting holder needs no polling. This covers manager-backed resources too. Any peer
could send similar text, so the agent confirms with `accord_reservation` before use.

Wakes cannot reach a closed application or a harness without a hook. They never type
into a terminal. The Windows waiters run in CI; no real harness has been woken on Windows.

## Identity and reconnects

The trusted host adapter reads the exact conversation ID from the harness hook
payload. After `accord_bootstrap` or `accord_announce`, it binds that ID to the
authenticated Accord address in the tool result. Existing launcher bindings via
`CODEX_THREAD_ID`, `CLAUDE_SESSION_ID` and `TESSERA_TILE_ID` still work, each only
for the client it belongs to; an inherited parent ID is ignored. Working
directories, labels and the most recently active session never establish identity.
Hooks carrying a child `agent_id` use the unread-count fallback, so a shared
parent conversation ID cannot overwrite the parent's binding or expose its mail.

Migration 10 retains these verified mailbox aliases. A new MCP connection bound
to the same native conversation can read and acknowledge prior unread mail,
including mail addressed to its closed predecessor. It cannot revive the old
credential, acquire its reservation or bypass stop-before-regrant recovery.
Messages in an old, unbound conversation stay retained; Accord does not guess a
new recipient for them.

The local `context-inbox` collaboration operation is administrator-only and is not
forwardable through host links. Host links still deliver messages to Messenger;
hooks and unread counts see the same durable state regardless of sender host.

## Retired recipients

A send to a retired address follows the retired session's successor chain
(resolved through at most ten hops) when it ends at a live recipient: the mail
is delivered to the successor and the send result carries
`redirectedTo: '<authority>/<id>'`. With no live successor the send still fails
immediately with `RECIPIENT_RETIRED` (410), naming the last known successor in
the error when one is recorded. The receiving host applies the same rule to
remote envelopes, so mail queued before a retirement lands with the successor
too; without one the sender's outbox marks that envelope `failed` permanently
instead of retrying it. Unread mail already delivered to the retired address
stays readable by the successor through the bound-conversation aliases
described above.

## Tile agents

A Tessera tile is its own observed session, but the agent running inside it
changes over time. `tileAgent(tile)` — used by `bridge-inbox` for `tessera`
observations — resolves the actor currently speaking for the tile: the
`tessera:<tile>` binding's actor followed through successors (≤10 hops) while
retired or closed, and when that chain dies or no binding exists, the most
recently linked live `agent`-role actor. Nested actors never qualify. The
bridge inbox returns mail for that actor plus the tile observation's own
inbox, deduplicated by delivery id, so mail addressed to the tile's real agent
is actually surfaced to the adapter. `agentRecord.tile` carries
`current: true` on the actor the rule picks.

Enrollment narrows who may claim a tile: Tessera exports
`TESSERA_TILE_AGENT=<flavor>` (claude, codex, devin, omp, agy, shell) in each
tile's environment. An MCP enrollment links as `agent` only when its client
family matches — codex clients need `codex`, claude clients need `claude`,
zcode needs `zcode`, and any other client needs a flavor outside
codex/claude/zcode/shell. A mismatch links as `nested` and never takes the
`tessera:<tile>` binding, so a scratch client run inside an agent's tile
cannot steal its mailbox. With the variable unset, enrollment behaves exactly
as before.

## Scheduled deliveries

A `schedule` produces ordinary outbox messages sent from the
`<authority>/accord-scheduler` principal, never from the owner, so they bypass
the self-message rule and cannot be mistaken for the owner's own words. The
message text reads `Scheduled by <owner label> (<schedule id>): <text>` plus
any event detail; the envelope data carries `scheduledBy` (the owner's
address) and `scheduleId`, which surfaces in the inbox view so adapters such
as Tessera can apply the owner's wake policy — including native-prompt
delivery when the schedule requested `wake`. Tessera types native-prompt
scheduled mail once the tile's agent is idle: before typing it checks
`bridge-unread` so a message the agent already read is dropped instead of
typed, and queued messages with the same `scheduleId` coalesce so only the
newest wake waits. Scheduled message ids are deterministic, so retries cannot
duplicate a delivery; every other outbox rule — `RECIPIENT_*` failures, expiry
and the durable queue — applies unchanged.

Schedules can be `persistent` (`expiresInMs` is refused alongside it): they
never expire and show `persistent: true` instead of `expiresAt`. They can be
paused with `schedule-pause` — paused rows ignore events and fires, resume
re-arms the trigger from now, and non-persistent paused rows still expire on
schedule. An interval schedule whose previous fire is still unread skips the
next fire rather than stacking wakes. A retired target at fire time follows
its successor when one is live and ends `target-retired` when none is. Rows
leaving `active`/`paused` keep a 72-hour retention window in `expires_at`
before the tick deletes them. The designated overseer may list all schedules
and pause or cancel any owner's rows.

`bridge-unread {ids}` lets a host adapter ask which delivery ids are still
unread (still pending or offered) before typing them.

## Qualification

`test/message-attention.test.mjs` covers delivery, deduplication, bounded output,
failure behavior, installer preservation, identity isolation, reconnects and
resource ownership separation. `test/mcp.test.mjs` checks the fallback over real
MCP stdio. The normal recovery and cross-host messaging suite remains required.
Real harness results are in [qualification](QUALIFICATION.md).

Hook contracts: [Claude](https://code.claude.com/docs/en/hooks) and
[Codex](https://learn.chatgpt.com/docs/hooks).
