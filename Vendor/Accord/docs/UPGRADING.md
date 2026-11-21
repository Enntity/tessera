# Upgrading Accord

## Before restarting

Finish or release active reservations on the host you are upgrading. Coordinate with
agents using resources on linked hosts. A coordinator restart fences unfinished tasks and
heartbeat reservations; it does not preserve their permission to continue. An unexpired
reservation window resumes once its driver reconfirms the same generation. Managed release
can stop a workload and restore its provider.

Keep the existing private data directory and connection profile. Do not initialize a
second authority or copy tokens between hosts. Keep the previous package available for
binary rollback; database rollback is a separate recovery operation and can invalidate
fencing history. See [recovery](RECOVERY.md).

## Install 0.8.1

```sh
npm install -g https://github.com/Enntity/accord/releases/download/v0.8.1/enntity-accord-0.8.1.tgz
accord install
```

No migration; fixes reconnect `KEY_REUSED` for native MCP bridges whose
enrollment predates 0.8.0. Restart the coordinator the way you did for 0.8.0;
the rest of this document applies unchanged.

## Install 0.8.0

```sh
npm install -g https://github.com/Enntity/accord/releases/download/v0.8.0/enntity-accord-0.8.0.tgz
accord install
```

The installer preserves other client settings and backs up files it changes. If it
finds an already running service, it updates the configuration but leaves the restart
to you. Follow the `next` command in its output once reservations are clear.

On Linux with the default systemd user service:

```sh
systemctl --user restart accord.service
```

On macOS, replacing the install path requires reloading launchd's service definition:

```sh
launchctl bootout "gui/$(id -u)/org.enntity.accord"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/org.enntity.accord.plist"
```

On Windows, use `accord install --no-start`, then restart `accord up` through your
chosen supervisor. Automatic Windows service installation is not included.

## Check the result

```sh
accord --version
accord doctor
```

The CLI should report `0.8.0`; the doctor should report `ready`. The CLI version identifies
the package invoked by your shell, so also check the running service's command line
against the new install path. Restart your agent sessions to load the updated MCP bridge.

On linked hosts, verify `accord find`, send and acknowledge a test message, and exercise
reserve, extend and release on a dedicated cooperative resource. Check that extension
keeps the claim and generation. Do not use an active GPU workload as a smoke test.

## Changes from 0.7.0

Two migrations. Migration 21 adds durable scheduled messages: the `schedules`
table (owner, target, trigger, rate limits, fire count and expiry) and the
`schedule_cursor` used to scan the events log for event triggers, plus an
`events(kind,at)` index for the per-hour rate checks. The cursor is initialised
to the end of the log at upgrade, so events logged before the upgrade never
fire a new schedule. Migration 22 adds the agent record: `agent_tiles`
non-exclusive tile links, the layered `titles` table (existing `given_title`
copied into the `peer` layer) and `sessions.client` for the connecting client's
name. Both apply in place; existing migration checksums and stored records are
unchanged.

Migrations 21 and 22 are forward-only: the 0.7.0 binary does not understand
them and will refuse an upgraded database. Rollback is therefore not
"reinstall 0.7.0" — restore the pre-activation database backup the deployment
procedure takes before the coordinator restarts, then run the 0.7.0 binary
against it. As before, never delete the migration record or restore older
fencing history just to make a downgrade start.

New operations are version-tolerant where it matters: a 0.8.0 client's
`session-link-tile` call is best-effort, so enrollment still succeeds against
an un-upgraded host, and `find {local:true}` never fans out. Operations a
0.7.0 host does not know (`overseer-designate`, `schedule`, `schedules`,
`schedule-cancel`, `topic-publish`, `workload-report`, `session-link-tile`)
answer unknown-operation on that host only; local behaviour is unaffected.
Schedule delivery is ordinary message delivery from the local authority's
`accord-scheduler` principal, so a schedule fires cross-host as soon as the
sending host is upgraded — the receiving host needs nothing new. Upgrade
linked hosts together so layered titles and agent records propagate; an
un-upgraded peer simply reports participants without the `agent` record.

## Changes from 0.6.10

Two migrations. Migration 19 adds session retirement: `retired_at`, `retired_reason`
and `successor` on sessions and observations, a `lifecycle` field on public records,
and the host's `lifecycle_since` floor. Migration 20 adds orphaned reservations: `orphaned_at`,
`orphan_reason` and `warned_deadline` on reservations, `orphan_grace_ms`, `age_out_ms`
and `registered_at` on `resource_bindings`, retirement columns on `remote_routes`, and
the `lifecycle_outbox` used to carry lifecycle notices between linked hosts. Both apply
in place; existing migration checksums and stored records are unchanged. The old 0.6.10
binary does not understand migrations 19 and 20 and will refuse that database; keep the
normal upgrade/recovery precautions above. Never delete the migration record or restore
older fencing history just to make a downgrade start.

Rollback after this release is therefore not "reinstall 0.6.10". As with 0.6.9, the
staged recovery package is the 0.6.10 implementation with migrations 19 and 20 added and
a distinct recovery version; it opens an upgraded database without rewriting its history.
Binary rollback is that recovery build, not the plain 0.6.10 archive.

Session retirement is configured by a new `lifecycle` section in `awareness.json`:
`observedRetireMs` (default 24 h) for observations scanned from transcript roots,
`joinedRetireMs` (default 72 h) for enrolled sessions and adapter-reported observations,
and `notify`, the addresses told when a claim holder goes stale. No `lifecycle` key means
the defaults. The automatic pass measures silence from no earlier than the upgrade (`lifecycle_since`),
so nothing retires for silence in the first 24–72 h afterward.
Review what the pass would retire first with `accord lifecycle sweep --dry-run`.

Upgrade all linked hosts together. A host running 0.6.10 or older answers a `lifecycle`
notice with an unknown-operation error; the notice stays queued and is retried for up to
seven days, then dropped with an event. A host upgraded late applies the retirement it
receives then, so a remote holder's orphan grace counts from that delivery.

## Changes from 0.6.9

No migration; the database and configuration are unchanged. A data directory whose
socket path exceeds the platform limit now serves its local socket from a private
`/tmp` directory, published through `endpoints.json` as before. A `session-report`
timestamp slightly ahead of the coordinator's clock is clamped to now instead of
rejected.

## Changes from 0.6.8

Migration 18 adds three nullable `session_views` columns for the given session title
and upgrades a 0.6.8 database in place; existing migration checksums and stored
records are unchanged. The old 0.6.8 binary does not understand migration 18 and
will refuse that database; keep the normal upgrade/recovery precautions above.
Never delete the migration record or restore older fencing history just to make a
downgrade start.

`session-title` names are local to each authority and never cross a link, so upgrade
all linked hosts together. See [API](API.md) and [session backplane](SESSION-BACKPLANE.md).

## Changes from 0.6.7

Migration 17 adds indexes without changing existing migration checksums or stored
records. The old 0.6.7 binary does not understand migration 17 and will refuse that
database; keep the normal upgrade/recovery precautions above. Never delete the
migration record or restore older fencing history just to make a downgrade start.

MCP reads use smaller pages and explicit detail requests. Update the coordinator
and MCP bridge together for the new inbox and history paging contracts. Legacy
HTTP defaults still return their previous full records. See [API](API.md#bounded-reads)
and [performance measurements](PERFORMANCE.md).

## Changes from 0.6.6

The prune pass that runs every ten minutes marks a session `exited` once it has sent no
heartbeat for 36 hours, the observer's transcript lookback. The first pass after upgrading
clears sessions that died before 0.6.7, which stops the overseer's check-ins to them. A later
heartbeat brings a session back as `idle`. A coordinator restart that resumes a window no longer
sends its holder a second "is running" notice. No schema migration is added.

## Changes from 0.6.5

A coordinator stalled past its leadership lease renews only if it still owns the
leadership token; a replacement or explicitly released token remains fenced.
The service records the gap as `coordinator.lease_recovered`. Resource deadlines
still apply. Managed-provider restoration retries retain a confirmed stop; a new
coordinator epoch or driver restart reconfirms it. No schema migration is added.

## Changes from 0.6.4

The installer compares the Codex Accord entry in `~/.codex/config.toml` by value, so an
upgrade no longer stops with "Existing Codex Accord MCP registration differs" after Codex has
re-saved the file. No schema change, so a 0.6.4 database upgrades in place.

## Changes from 0.6.3

`accord resource remove --id NAME` lets the administrator of the host that owns a resource
retire it. It works for every plugin and refuses while anything holds, queues on or depends
on the resource. No schema migration is added, so a 0.6.3 database upgrades in place.

## Changes from 0.6.2

A `managed-http` resource whose provider answers availability with 404 `resource_unknown`
is removed once nothing holds, queues on or depends on it; the first pass runs a second
after the coordinator starts. Providers that never answer that way are unaffected. No
schema migration is added, so a 0.6.2 database upgrades in place. Upgrade the host that
owns a resource for its withdrawals to take effect.

## Changes from 0.6.1

A coordinator restart keeps an unexpired reservation window: its claim returns to
`preparing` under the same generation and deadline until the driver reconfirms it.
Heartbeat reservations and tasks are still fenced. No schema migration is added, so a
0.6.1 database upgrades in place; the first 0.6.2 start resumes windows recorded by 0.6.1.

## Changes from 0.5

CLI and MCP reservations default to a one-hour window. `durationMs` sets a bounded
window; `leaseMs` explicitly selects a supervised heartbeat. An extension preserves the
claim and generation. New clients refuse window requests on old hosts before changing
anything, so upgrade all linked hosts before relying on this feature.

The schema adds migration 16. Existing heartbeat reservations retain their recorded
lease deadline during migration; the normal restart fencing rules still apply.

0.6.1 also renews supervised leases during preparation and exits on fatal coordinator
storage or leadership failure so the installed service manager can restart. A disk
that remains full still needs free space; restarting cannot repair it.
