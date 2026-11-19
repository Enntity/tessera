# Changelog

## 0.7.0

- Orphaned reservations (migration 20): a session retired with `tile-closed`,
  `process-exited`, `superseded` or `operator` orphans the reservations it holds
  in `preparing`/`running`. Each reports `orphaned {since, reason, releaseAt}`
  and releases after the resource's `orphanGraceMs` (0–24 h, default 15 min);
  the ordinary fence then applies — managed holds wait for provider-confirmed
  stop and an unconfirmed release stays held. Revival inside the grace reclaims
  the same claim and generation; a successor inherits nothing, hears the orphan
  and the end, and must reserve again, as does each `lifecycle.notify` address.
  Retirements and revivals also propagate over host links through a durable
  `lifecycle` notice: the resource host applies the same orphan/stale/fence
  rules to the session's remote actor, with the grace counted from receipt.
- Window reservations warn the holder once per deadline before expiry, at a
  lead of 10% of the window clamped between one and fifteen minutes; extending
  re-arms the warning and retired or closed holders are never warned.
- `cooperative` manifests may declare `ageOutMs` (0 = never, default 30 days):
  an idle cooperative resource leaves the catalog after that period, measured
  from its `registered_at`, with `resource.aged_out` recorded.

- Session retirement (migration 19): sessions and observations gain `retired_at`,
  `retired_reason` and `successor`, and public records gain a `lifecycle` field
  (`live`/`idle`/`stale`/`exited`/`retired`) alongside the unchanged `presence`.
  Explicit close retires with reason `closed`; the admin `lifecycle-retire`
  operation (`accord retire`) retires a session or everything bound to a native
  observation; a host-observed `exited`/`cancelled` report retires the observation
  and — when the reporter owns it — its bound actors.
- The periodic silence pass retires observations quiet for
  `lifecycle.observedRetireMs` (default 24 h) and enrolled sessions for
  `lifecycle.joinedRetireMs` (default 72 h) in `awareness.json`, floored by
  `lifecycle_since` so the upgrade backlog ages from the migration. Silent
  claim holders go `stale` with one `lifecycle.notify` notice per claim
  generation; queued reservations of retired sessions are cancelled.
- Retired records stay readable by id but leave `find`, `sessions`, bootstrap
  previews and quiet-work check-ins (`includeRetired` opts back in). Retiring
  resolves open incidents (`subject-retired`). Authenticated activity revives a
  silence-retired session; a transcript rescan revives only with activity newer
  than its retirement, so dead subagents stay retired. Sends to a retired
  address fail `RECIPIENT_RETIRED` with the successor, permanently and without
  retries, including over host links. `lifecycle-sweep`
  (`accord lifecycle sweep [--dry-run]`) retires the true backlog on operator
  review and emits `lifecycle.swept`.

## 0.6.10

- A `session-report` whose `sourceProgressAt` runs slightly ahead of the coordinator's
  clock is clamped to now instead of rejected, so an adapter on a faster clock no longer
  loses its reports; a timestamp more than a day ahead is still `INVALID_INPUT`.
- A data directory whose `accord.sock` path exceeds the platform socket limit no longer
  fails `up` with `DATA_PATH`: the local socket binds in a private `/tmp` directory
  instead (`0700`, the socket `0600`, a symlinked or foreign-owned path is refused), is
  published through `endpoints.json`'s `local` URL like before, and is removed with its
  empty directory on close. `hook.sh` finds it through `endpoints.json`, so hold and
  wake keep working for long data paths.

## 0.6.9

- `accord_title` (through `accord_more`; CLI `title`) gives any session a display name
  for the operator and other agents, addressed by id or by an adapter's source and
  external id. The name is attributed (`givenTitle`, `titledBy`, `titledAt`), redacted,
  searchable, and removed with an empty title. It is not progress, leaves the owner's
  own title in place, is cleared when a session becomes private, and cannot be set
  from a linked host. Compact session lists show the given name. Adds one migration.
- `sessions` accepts `source` to list one adapter's sessions, live ones first, so an
  adapter can read back everything it reported regardless of how long ago it progressed.

## 0.6.8

- Discovery compaction counts serialized bytes incrementally and groups pools once.
  Local resources now appear in `find`, alongside linked resources.
- Migration 17 adds indexes for active claims, queues, sessions, mail and manager
  requests. Closed history no longer dominates reconciliation queries.
- Ownership changes trigger reconciliation immediately. Up to four independent
  resources progress concurrently, with one driver operation per resource.
- Concurrent host reads share their in-flight observation; later reads remain fresh.
  Window capability checks no longer fetch the full resource catalog.
- MCP inbox, resources and board reads use pages. Session search returns compact
  metadata, with full records and older activity available explicitly. Message
  bodies and durable history remain complete. Legacy HTTP defaults are preserved.
- Memory indexing runs in a reusable worker, transcript reads avoid overlapping
  windows, and quiet-session checks skip resolved historical sessions.

See [performance evidence](docs/PERFORMANCE.md) for measurements and tradeoffs.

## 0.6.7

- A session that has sent no heartbeat for 36 hours, the same window observers use for
  transcripts, now shows as exited. Before, it stayed "working" on the board and the overseer
  kept checking in with it. If it later heartbeats again, it comes back as idle.
- A coordinator restart that resumes a window no longer tells the holder its window "is
  running", since it already knew.
- A window that reaches its deadline is reported as "reached its deadline and ended" instead
  of "ended as failed".

No schema change.

## 0.6.6

- A coordinator delayed past its leadership lease can continue if no replacement
  took over. It records the gap and preserves live claims; expired claims and
  replaced leadership tokens remain fenced.
- A failed managed-provider restore retries restoration without repeating a
  confirmed workload stop. A coordinator takeover or driver restart reconfirms
  the stop, and the resource stays held until restoration succeeds.
- CI fixtures use the production leadership lease on every platform. Wake tests
  bind their setup through the admin API instead of the hook's 500 ms deadline.

## 0.6.5

- Upgrading no longer stops with "Existing Codex Accord MCP registration differs" after Codex
  has re-saved `~/.codex/config.toml` in its own style. The installer now compares the Accord
  entry's values, not its exact text.

No schema change: a 0.6.4 database upgrades in place.

## 0.6.4

- `accord resource remove --id NAME` retires a resource nobody needs any more, such as a second
  name for something that already has one. It refuses while anyone holds or waits for the
  resource, removes its history and driver files like a withdrawal, and keeps fencing safe if the
  name is registered again. Removing a name that is already gone changes nothing.

Run it on the host that owns the resource, after upgrading that host. A 0.6.3 database upgrades
in place.

## 0.6.3

- A `managed-http` resource its provider no longer offers no longer stays forever. The provider
  answers `availability` with 404 `resource_unknown`, and the resource is removed once it is idle,
  together with its finished history and driver files. Fencing stays safe: a name registered again
  starts above every generation it issued. Unreachable providers keep their resources.

Upgrade the host that owns a resource for its withdrawals to take effect. A 0.6.2 database
upgrades in place.

## 0.6.2

- A coordinator restart, such as a supervisor restart after an OOM kill, no longer ends an
  unexpired reservation window. The same claim and generation return to `preparing` and the
  driver reconfirms them; managed and cooperative drivers do so across their own restart.
  A driver that cannot resume the generation, such as a restarted process driver, gets it
  revoked at once instead of left preparing until the deadline.
- A holder that did not release is told when its reservation ends.

Upgrade the host that owns a resource to keep its windows across restarts. Restarting into
0.6.2 already resumes unexpired windows recorded by 0.6.1.

## 0.6.1

- CLI and MCP reservations use a one-hour bounded window by default. Extend the same
  grant without preparing the provider again or restarting the workload.
- Supervised heartbeat reservations renew during slow preparation, before work begins.
- Fatal coordinator storage and leadership failures retain their original diagnostic
  and exit nonzero, allowing launchd or systemd to restart the service.
- CLI version output and MCP initialization read the version from the installed package.
- Installation, upgrade and recovery documentation distinguish supported behavior from
  client-specific and unqualified paths.

Upgrade all linked hosts for reservation windows. Existing raw heartbeat clients remain
compatible. Restarting a coordinator fences unfinished grants, so release active work
first. See [upgrading](docs/UPGRADING.md).

Validation includes SQLite `SQLITE_FULL` induced by a page limit, leadership loss in a
child process, slow provider preparation, generation-preserving extension, and recovery
before regrant. Full-filesystem exhaustion and power loss are not qualified by these tests.

## 0.5.0

- Stable native MCP mailboxes across reconnects and explicit remote-delivery errors.
- Clean service stops and updates from moved installation paths.
- Optional memory search, disabled by default, with provenance and bounded reads.
- Resource-declared ownership limits.
