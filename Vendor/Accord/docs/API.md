# HTTP contract

All routes require a bearer credential except the board's static assets and
the minimal `/.well-known/accord` descriptor. The
coordinator and driver bind only `127.0.0.1`. On macOS and Linux the coordinator also
listens on `accord.sock` in the private data directory, and `endpoints.json` names it
as `local`; local clients use that and never fall back to TCP. Host and Origin are checked; no CORS
access is enabled. A JSON request body is limited to 32 KiB. Redirects are never
followed by the client. Errors are `{error:{code,message}}` with HTTP status.

Authenticated worker responses, including errors after authentication, also carry
`inboxPending: N` when inbox deliveries are pending. Zero is omitted.
A failed count yields `inboxPending: "unknown"`; clients should check their inbox.
The hint never acknowledges a delivery and adds no client request. Discovery and
operator responses do not inherit worker mail. Driver-only operations and local
commands that never contact the coordinator cannot supply this hint.

Every coordinator mutation requires a `key` (1–128 characters). Keys are unique
per actor across operations. A retry with the same serialized payload returns
the original response. A different payload or operation with that key returns
`KEY_REUSED`. Use a fresh key for a new attempt, task, renewal, or checkpoint.
Errors are not memoized. A retried claim returns its current status; a closed
claim never returns its old resource credential.

| Method | Route | Body or result |
| --- | --- | --- |
| GET | `/health` | Authenticated leadership health |
| GET | `/v1/me` | Authenticated `{id,role}` |
| GET | `/v1/board?after=0` | Tasks, claims, holds, admission state and up to 500 events; optional `active=true`, `limit=1..100`, `before` |
| POST | `/v1/tasks` | `{key,title,input,expectedHash,dependency?,maxAttempts?}` → `{taskId}` |
| POST | `/v1/claim` | `{key,taskId?,leaseMs?}` → claim, task, driver URL; resourceToken only when active |
| GET | `/v1/claims/{id}` | Owner-only claim status, task and active resource credential |
| POST | `/v1/claims/{id}/checkpoint` | `{key,note}`; current owner only |
| POST | `/v1/claims/{id}/renew` | `{key,leaseMs}`; cannot revive an expired attempt |
| POST | `/v1/claims/{id}/finish` | `{key,receiptId}` → verified and releasing; success follows release confirmation |
| POST | `/v1/tasks/{id}/cancel` | `{key}`; admin only; requested and confirmed cancellation are distinct |
| POST | `/v1/steer` | `{key,paused:boolean}`; admin only |

If taskId is omitted, claim selects the oldest eligible queued task. The service
does not grant ownership to a mere observer. A busy task/resource returns 409.
Only `succeeded` unblocks dependencies. Dependencies must refer to preexisting
tasks and cannot be edited, preventing cycles in this initial API.

The task's expectedHash is a lower-case SHA-256 digest. `input` is at most 8,000
characters; checkpoint notes are at most 4,000. Tasks are immutable after submit
apart from their lifecycle, checkpoint and result. This release has a 5,000-task
limit, 100,000 accepted-command limit, and 100,000-artifact limit. History is not
pruned. It is a bounded database, not a long-lived retention service.

## Bounded reads

Legacy HTTP reads retain their full records. Optional paging selects a smaller view;
no history is deleted and reading never acknowledges a message.

- Board: `limit` selects the newest task page; pass `nextBefore` as `before` for
  older tasks. Tasks within each page remain oldest first. `active=true` selects
  live tasks and claims. Resource holders always include all open claims, even
  when their tasks are outside the page. The event `after`/`cursor` is independent
  of task paging. MCP defaults to 20 task previews; `detail:true` returns the same
  page with complete task records. The web board requests the active view.
- Collaboration `inbox`: `limit` (default 20 when paging, maximum 100) or `cursor`
  opts into pages capped near 24 KiB, retaining complete message bodies. Pass the
  returned `cursor` unchanged for the next page. It identifies a delivery owned
  by this inbox and remains valid after that delivery is acknowledged. MCP opts
  into paging by default. Without these arguments the legacy HTTP read is
  unchanged. Only `read` acknowledges. A single oversized legacy delivery is
  returned whole with `oversized:true` so paging always makes progress.
- MCP resources: pages default to 20 records within roughly 8 KiB, including pool
  summaries. Pass `cursor` for more. An oversized single record remains whole
  and is marked `oversized:true`. HTTP catalogs remain complete.
- MCP sessions: summaries are bounded to 8 KiB; `detail:true` returns full session
  metadata for the requested search and limit. `session-read` defaults to 10
  complete events. Pass its `previous` as `before` for older events, or use `after`
  for newer ones. Both event directions accept `limit=1..200`. Raw HTTP retains
  its default of 60 events.

Pages describe a changing system, not a snapshot. New records before a cursor
appear on a fresh first-page read. Paging on an older linked host may return its
legacy response until that host is upgraded. These views do not change ownership,
privacy checks, receipt validation, or durable retention.

## Driver API

Workers receive only the resource credential for their current claim. It is an
HMAC derived from the coordinator's private secret and claim ID; the driver stores
its hash. Board and event responses never include credentials.

`POST /v1/artifacts` accepts `{key,content}` using that resource credential. It
validates the active grant and atomically stores UTF-8 content and a receipt.
The same key within one claim returns the original receipt for identical content;
different content is rejected. A revoked credential cannot replay even this
write route. Content is limited to 8,000 characters.

The coordinator separately holds the driver's control credential. Control routes:

| Route | Contract |
| --- | --- |
| GET `/control/status` | Driver instance, bound authority, highest epoch/generation, active claim |
| POST `/control/activate` | `{instance,authority,epoch,generation,claimId,credentialHash,holder?}` |
| POST `/control/revoke` | `{instance,authority,epoch,generation,claimId}` |
| GET `/control/receipts/{id}` | Receipt metadata for acceptance validation |
| GET `/control/artifacts/{id}` | Stored artifact content |
| GET `/control/audit` | Ordered driver grant, revoke, restart, and write records |

Control commands persist before acknowledgment. A same-generation activation is
idempotent only while that exact grant remains active; once revoked, that
generation cannot become active again. Revoke creates a tombstone even if the
matching activation has not arrived. A higher generation cannot replace an active
grant without release. A different driver instance or coordinator authority is
refused rather than silently adopted.

## Client example

```js
import { readFileSync } from 'node:fs';
import { AccordClient } from './src/client.mjs';

const client = new AccordClient('http://127.0.0.1:8787',
  readFileSync('.accord/agent-a.token', 'utf8').trim());
let claim = await client.claim();
while (claim.state === 'preparing') {
  await new Promise(resolve => setTimeout(resolve, 100));
  claim = await client.inspect(claim.id);
}
if (claim.state !== 'running') throw Error('Grant did not become active');
await client.checkpoint(claim.id, 'Input inspected; preparing the output.');
const receipt = await client.write(claim, claim.task.input.toUpperCase());
await client.finish(claim.id, receipt.id);
```

This sample assumes the task expects uppercase output. A real adapter chooses its
own work implementation and renews before its deadline. A driver receipt proves
an artifact was stored; the configured digest check proves only exact equality,
not general semantic quality.

## Bootstrap and discovery (0.2)

Migration 2 adds session, purpose-credential, and peer tables without altering
migration 1. Existing authority, claims, checkpoints and generations are retained.
The coordinator's startup adds bootstrap credentials to original preview data;
stop the old service before upgrading. The original actor credentials still work.

| Method | Route | Authorization and result |
| --- | --- | --- |
| GET | `/.well-known/accord` | No credential; only protocol and authority ID, while coordinator is healthy |
| POST | `/v1/sessions` | Enrollment credential; `{key,authority,label,harness,ttlMs?}` → distinct session, expiry, session credential |
| POST | `/v1/sessions/{id}/close` | Session owner or admin; `{key}` → closed; held resources still require confirmed release |
| GET | `/v1/bootstrap` | Worker/admin; identity, live host metadata, directly paired peers, durable board |
| GET | `/v1/host` | Discovery credential or worker/admin; host identity and current ownership metadata |
| GET | `/v1/network` | Worker/admin; local host plus direct peers, each observed or unknown |
| POST | `/v1/peers` | Admin; `{key,authority,url,credential}` pins a verified peer discovery connection |
| POST | `/v1/peers/remove` | Admin; `{key,authority}` removes that discovery connection |
| POST | `/v1/claims/{id}/artifact` | Active owning worker; `{key,content}` writes through the local driver |

The enrollment response is the only bootstrap response containing a session
credential. The service stores its hash; the value is derived from a private
secret and session ID, allowing idempotent enrollment retries. Closed or expired
sessions cannot be reactivated by replay. Session metadata on the board has no
credential. Discovery exposes no task input, checkpoint content, or peer secrets.

The proxy artifact endpoint allows one SSH forward for remote worker traffic.
The host authenticates the session and current claim before contacting its local
driver; the driver checks its current grant again. Revocation in flight remains
an unknown-release interval, not a claim that all external processes have stopped.

MCP exposes bootstrap, host, board, claim/wait/status, checkpoint, renewal, artifact
write and finish. Tool mutation keys are explicit. Tools do not return driver
credentials and cannot add peers, impersonate another session, or steer as admin.
A tool wait returns at most a preparing/running claim; inspect before effects.
The CLI/JS wait helper is bounded polling, not a durable fairness queue.

Peer addresses in this version are loopback HTTP origins, normally SSH forwards.
Host validation accepts loopback names with forwarded ports. Browser Origin must
match the request Host exactly, and CORS remains disabled. The public descriptor
is discovery metadata; trust comes from an explicitly pinned authority and the
separately provisioned credential, not merely seeing a UUID.


## Reservation windows (0.6)

`capabilities` on `/v1/collaboration` returns `reservation-windows-v1` without
fetching the resource catalog. Older hosts advertise it through `resources`; the
client falls back only when the lightweight operation is unsupported. Verify this
on the owning host before sending a window to it;
older hosts do not understand the new field. `reserve` accepts `durationMs`
(1 second to 30 days), mutually exclusive with `leaseMs`. CLI, MCP and
`AccordClient.reserve` default to a one-hour window. Raw legacy HTTP requests
without either field retain the five-minute heartbeat default.

The window starts at claim acquisition and includes preparation. Reservation
status includes `mode` (`window` or `heartbeat`), `renewalRequired`, and the
absolute `deadline`. A window needs no renewal calls while the chat is idle.
`renew` accepts `durationMs` to extend the same claim to at least that duration
from now, including conversion of a live heartbeat lease. It never shortens a
previous deadline; same-key retries never move it again. Ownership limits,
owner authentication, session revocation and confirmed recovery still apply.
Compatibility resource managers reject windows with `WINDOW_UNSUPPORTED`.

## Workload observations (0.7.x)

A host administrator posts `workload-report` to `/v1/collaboration` with
`{key,source,ttlMs?,items}`; each report replaces the source's previous report
and lives in memory until `ttlMs` (10 s–1 h, default 3 min) — nothing is
persisted, so senders re-report periodically. Items are bounded (`id` ≤120,
`state` ∈ running/starting/stopping/stopped/suspended/failed/unknown, plus
optional `node`, `container`, `model`, `since`, `by`, `operationId`, `note`).
Reports surface under `workloads.reports` in host telemetry.

Local `resources` and `reservation` answers gain a `workloads` object on each
resource with a non-empty `hosts` list: `{observedAt, note:'Observed on the
host; not ownership', hosts, items}`. Only these two read operations are
enriched — reserve, release and other mutations return unmodified. These are
observations only — they grant no ownership and never gate admission. See
`docs/telemetry.md` for collection, host-name resolution and the owner-label
precedence.

Managed `prepare` bodies now include `holder:{label,address}` of the claim's
actor. Providers may ignore unknown fields; LLooM does.
## Scheduled messages (migration 21)

`schedule` (worker/admin, idempotent by `key`) creates a durable schedule that
delivers a message as the `accord-scheduler` principal: `{key, to?, text,
wake?, at?, inMs?, everyMs?, startAt?, on?, expiresInMs?, maxFires?}`. `to`
defaults to the caller's own address and is validated the way `send` validates
its recipient; `wake` requests `native-prompt` delivery. Exactly one trigger:

- `{at}` or `{inMs}`: one-shot; after downtime it fires once with a late note.
- `{everyMs >= 60000, startAt?}`: repeats until expiry or `maxFires` (1-10000).
- `{on:{event:'reservation',resource,states?}}`: `claim.active` maps to
  `active`; `claim.released`, `claim.expired`, `claim.orphan_expired` and
  `reservation.reclaimed` map to `released` (default both). Local resources
  only; use `host` to create it on the owning host.
- `{on:{event:'job',job,states?}}`: `job.updated` fires only on state change.
- `{on:{event:'idle',session,idleMs>=60000}}`: fires once when a local
  session's last activity exceeds `idleMs`, and re-arms on new activity.
- `{on:{event:'topic',topic}}`: `topic-publish` `{topic,text?<=500}` —
  rate-limited to 60 per actor per hour — fires matching schedules.

Event triggers scan the durable `events` log in bounded batches, so nothing is
lost while the coordinator is down. Events within 60 seconds coalesce into one
message (`pending_events` keeps the last five summaries). One owner is limited
to 50 active schedules (admin exempt), 60 firings per hour (later fires defer
to the next minute) and 30-day expiry (default 7 days). A retired, expired or
closed owner cancels its active schedules; a target that no longer exists at
fire time marks the schedule `failed`. Each delivered message carries
`scheduledBy` (the owner's address) and `scheduleId` in its envelope data, and
its id is deterministic (`hash(scheduleId:firedCount)`), so a retry cannot
double-send.

`schedules` lists the caller's own schedules (`{all:true}` for admin);
`schedule-cancel {id}` ends an owned or admin schedule. All three are
forwardable, so agents on linked hosts schedule on the resource's own
authority.

## The agent record (migration 22)

Participants in `find`/`sessions` carry an `agent` object: `{host:{authority,
name}, client, tile?, title, titleSource, task?, previous?, native?}`.
`client` is the name recorded at enrollment (`accord session open` passes `cli`,
the MCP bridge passes the client's `clientInfo.name`, `accord run` the command
basename). `tile` is a non-exclusive `agent_tiles` link `{id,role}` — `agent`
for the tile's own bridge, `nested` for sessions opened inside it; a legacy
`tessera` mailbox binding reads as an `agent` link. `native` is the mailbox
binding, `task` the latest working/waiting job title (else the announced
activity), and `previous` up to five earlier session addresses walked backwards
through the supersession chain.

Titles come from their origin. `title` is the linked Tessera tile view's
title when the agent has a tile, else the agent's own session view title,
else its label; `titleSource` is always `origin`. `session-title` renames at
the source: it finds the subject's Tessera tile and enqueues a `kind:"rename"`
bridge delivery to it, returning `{rename:"requested",tile,title,session}`
and emitting `session.rename-requested`. It refuses with `RENAME_UNSUPPORTED`
when the subject has no tile, when the tile view reports `rename:"unsupported"`
(the tile's `renameReason` becomes the message), or when an older Tessera
reports no rename field ("Tessera on this host can't rename sources yet.");
an empty title is `INVALID_INPUT` — a name can't be removed at the source.
`kind:"rename"` is only ever created by `session-title`; `send` still coerces
caller kinds to `message`/`notification`. Tile views report their rename
support through `session-report` fields `rename` (`supported`|`unsupported`)
and `renameReason`. `overseer-designate {address|null}` (admin) names the
host's overseer; the current designation appears in the `overseer` answer.

Native mailbox bindings are created only from an explicit trusted identity —
the MCP client's own ID or `accord session open --native SOURCE:ID`. CLI
enrollment never binds environment IDs (an inherited parent ID is ignored);
when `TESSERA_TILE_ID` is present it records a `nested` tile link through the
admin-only `session-link-tile {actor, tile, role}` operation.

`find {local:true}` returns only this host's entry: no forwarding to linked
hosts, even for admin. Adapters polling every few seconds for local tiles
should pass it.
