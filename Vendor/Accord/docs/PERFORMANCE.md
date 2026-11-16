# Performance pass: November 2026

This pass reduces work that grew with retained history and bounds the context sent
to agents. It preserves durable messages, task history, ownership fencing and
release confirmation. It adds no runtime dependency and does not modify vendored
Messenger. Measurements are local fixtures, not a production capacity guarantee.

## Reproduce

Use Node 22.16 or newer. Run the candidate's harness against both checkouts so the
inputs and measurement code are identical:

```sh
node scripts/benchmark.mjs /path/to/baseline evidence/before > evidence/before.json
node scripts/benchmark-http.mjs /path/to/baseline > evidence/http-before.json
node scripts/benchmark.mjs /path/to/candidate evidence/after > evidence/after.json
node scripts/benchmark-http.mjs /path/to/candidate > evidence/http-after.json
python scripts/benchmark-tokens.py evidence/before/token-fixtures.json evidence/after/token-fixtures.json
```

The optional Python script uses `tiktoken` in a separate development environment;
it is not a product dependency. It counts serialized tool definitions and synthetic
message payloads, not provider-specific framing, reasoning, tool-call or cache
charges. It aligns delivery IDs, sender/recipient addresses and timestamps to the
first fixture, verifies identical message bodies, and preserves page boundaries
and cursor calls so random metadata cannot skew the comparison. The JSON harness records a SHA-256 of the source tree, Git revision,
runtime, CPU, response bytes, p50/p95 and query plans. All fixtures are temporary.

The history benchmark directly seeds up to 100,000 completed tasks/claims to test
query scaling beyond the public task-admission cap. It does not raise that cap.
The HTTP benchmark uses eight cooperative resources and measures the complete
reserve → running → extend → release → released workflow, including polling.
Memory fixtures contain 128 files of 512 KiB each; a zero-delay timer measures
how long indexing prevents the coordinator event loop from responding.

## Results

Measured on Apple M2 Max, macOS arm64, Node 22.19.0. Baseline is
`4755eae3314df894b0f661864ccba5d46106565e` (0.6.7). Three repetitions per
checkout; tables show the median of run medians and the median of run p95s.
Initial runs alternated baseline/candidate order; final candidate runs were
repeated sequentially after the transcript and paging-boundary fixes. No other qualification
suite ran alongside the measurements.

The baseline source-tree digest was
`e21983d9a8ffffa681515fe0c62fcfd5c3ef51be56c087fa36cf132a2859b816`;
the candidate digest was
`e3a749c61ccf3dda70a7f09932c157d1ea97e0dd1f161b30c2c41661b4a67117`.
These hash all `src/` files with relative names using `benchmark.mjs`'s algorithm.

| Fixture | Baseline p50 / p95 (ms) | Candidate p50 / p95 (ms) |
| --- | ---: | ---: |
| Compact 64 resources | 0.168 / 0.264 | 0.067 / 0.253 |
| Compact 512 resources | 18.880 / 19.423 | 0.511 / 0.649 |
| Compact 2,048 resources | 325.114 / 341.192 | 1.942 / 2.216 |
| Pending claims, 100k closed claims | 6.453 / 7.097 | 0.008 / 0.010 |
| Queue scheduling, 100k completed tasks | 3.700 / 4.291 | 0.011 / 0.012 |
| Full historical board, 100k tasks/claims | 350.113 / 460.800 | 396.032 / 490.003 |
| Live board after 100k completed tasks | 357.384 / 485.871 | 0.062 / 0.069 |
| Newest 20-task page after 100k tasks | 353.227 / 459.644 | 0.162 / 3.138 |
| One HTTP host read, eight resources | 2.327 / 3.201 | 2.206 / 3.218 |
| HTTP bootstrap | 2.427 / 3.244 | 2.563 / 3.296 |
| 16 concurrent HTTP host reads | 21.814 / 25.157 | 5.382 / 10.049 |
| Full reservation workflow | 90.401 / 95.921 | 89.476 / 94.584 |
| Scan one 512 KiB memory file | 0.910 / 4.195 | 1.195 / 32.152 |
| Scan 128 × 512 KiB memory files | 62.299 / 67.678 | 69.975 / 73.414 |
| Event-loop timer delay during 128-file scan | 62.356 / 67.870 | 1.342 / 1.446 |

Synchronous functions use three warmups and 31 samples, except board views use
seven. HTTP reads/workflows use three warmups and 21 samples (11 for bursts).
Memory uses seven scans; the first one includes worker startup, explaining the
one-file p95. The baseline ignores the new board options and returns full history;
those rows compare the equivalent caller need, not identical response contents.
Full export is retained and was 13.1% slower in this fixture; it is not a claimed
improvement. Ordinary reservation latency changed modestly. The independent-driver
regression separately proves progress while another driver is stalled.

Inserting the final 90,000 closed task/claim pairs took 557.8 ms before and 786.8 ms
after (+41.0%). Database plus WAL size at 100,000 pairs grew from 27,270,088 to
30,807,520 bytes (+13.0%). This synthetic bulk write includes the new historical
claim lookup index. These are real costs of faster reads; no durability settings
were weakened to reduce them. Whole-process peak RSS for the mixed benchmark
fell from 1.86 GB to 1.52 GB, but this includes repeated historical exports and GC,
so it is not a steady-state service-memory estimate.

For 100 synthetic 4,000-character messages, the first response fell from 426,904
to 21,418 bytes. Reading all 20 pages, including requests, took 430,616 bytes
versus 426,968 (+0.85%). Exact token counts for the recorded payloads:

| Payload | o200k baseline → candidate | cl100k baseline → candidate |
| --- | ---: | ---: |
| Default 12-tool catalog | 911 → 923 | 884 → 894 |
| First inbox response | 79,279 → 4,004 | 79,181 → 3,996 |
| Entire backlog, requests + responses | 79,290 → 80,728 | 79,193 → 80,633 |

First-response tokens drop about 95%; consuming the entire backlog adds about 1.8%.
The default catalog remains below 4 KiB (3,984 → 3,969 bytes), with 12 extra
o200k tokens for the new controls after shortening descriptions. IDs and message
timestamps are aligned between each baseline/candidate pair; rerunning the
baseline can still change absolute totals slightly. Full message bodies are identical. This pass preserves the 12 default tools and lazy access
to uncommon tools through `accord_more`.


## Implementation and tradeoffs

- JSON compaction counts each removed record once, including UTF-8 and escaping.
  Pool aggregation uses one pass instead of repeatedly filtering all resources.
- Migration 17 adds partial indexes for live work and lookup/order indexes for
  session activity, directory, mail, incidents and manager requests. Inserts pay
  index maintenance costs; retained records and published migrations are unchanged.
- Reconciliation is triggered by durable events and deadlines, with a one-second
  idle fallback. Four independent driver operations can run at once; each resource
  still has at most one operation in flight. Failure retries yield their slot.
- Concurrent host/catalog reads share only an unfinished observation. Subsequent
  calls start fresh, so there is no new ownership cache or invalidation policy.
  Capability checks use a small authenticated response instead of a catalog.
- Active board reads avoid historical rows. Legacy full reads remain available;
  task pages and event cursors are independent. MCP previews direct callers to
  full records when needed. Inbox pages preserve entire bodies and explicit read
  acknowledgements. See [the read contracts](API.md#bounded-reads).
- The memory scanner reuses one worker, sends metadata only, and releases it after
  a minute idle. This protects coordinator responsiveness at the cost of worker
  startup and a separate V8 isolate. It does not make filesystem work disappear.
- Transcript scanning avoids duplicate reads/parsing of overlapping windows;
  contiguous windows preserve records spanning their boundary. Quiet-session
  checks visit working sessions and unresolved conditions, rather than all history.

The first inbox page is much smaller, but consuming every message requires extra
calls and paging metadata. No benchmark here claims a full-backlog token saving.
Small scans can cost more with a worker. Full historical export still scales with
history. Local HTTP medians include operating-system and scheduling noise; reserve
latency is also quantized by the fixture's polling interval.

## Audit coverage

The pass traced these source groups and their callers. Changes target repeated
work and unbounded presentation; unchanged paths retain their existing contracts.

| Area | Source modules reviewed | Decision |
| --- | --- | --- |
| Ownership and persistence | `store`, `server`, `common`, `reservation-policy`, `query-schema`, `async-work` | Index live work, schedule on events, preserve transactional leadership and generation checks. Keep WAL/FULL durability and accepted-command tombstones. |
| Collaboration and agent context | `collaboration`, `client`, `mcp`, `compact`, `bootstrap-view`, `discovery-view` | Bound/paginate reads, batch joins and pool grouping, coalesce observations. Keep the already bounded bootstrap preview and discovery/observer distinction. |
| Sessions and observation | `session-awareness`, `session-continuity`, `session-summaries`, `observers`, `product-observers`, `awareness-runtime`, `discovery-cleanup` | Add event paging and lookup indexes; avoid duplicate transcript parsing. Keep revision-checked summaries, changed-input scheduling, redaction and privacy. |
| Attention and oversight | `attention`, `message-attention`, `overseer`, `context-hook`, `wait-hook`, `hook.sh` | Index mailbox/incident lookups and limit quiet checks to relevant sessions. Keep delivery wake budgets, burst settling and explicit acknowledgement. |
| Memory | `memory-panorama`, `memory-worker` | Move scans off the coordinator loop; reuse statements and stop listing after enough matches. Retain original adapters and explicit body-read validation. |
| Resource enforcement | `driver`, `driver-host`, `managed-driver`, `process-driver`, `process-anchor`, `process-schema`, `resource-plugins`, `plugins/posix-process-group` | Preserve serialized per-resource effects, bounded registries, provider confirmation and durable revoked generations. No weaker stop or receipt checks for speed. |
| External workloads/managers | `workload-guard`, `workload-host`, `workload-transport`, `workload-schema`, `resource-managers` | Index active manager polling and receipt lookup. Retain bounded batches, connector identity, registered-target rules and stop-before-release. |
| Telemetry | `telemetry`, `telemetry-collectors`, `native-sensors` | Retain existing single-flight caches, bounded collectors, stale/null semantics and on-demand sampling. |
| Setup and transport | `bootstrap`, `config`, `connect`, `service`, `installer`, `client-install`, `product-install`, `hook-install`, `cli`, `version` | Preserve credential selection, private sockets, authenticated link proof, configuration backups and service lifecycle. No new transport or competing implementation. |
| Web UI | `ui.js`, `ui.html`, `ui.css` | Request the active board used by the live task view; preserve controls, ownership states, history search and presentation. |

## Verification

Local `npm run verify` passed 313 tests and checked 114 JavaScript modules. The
recovery, bootstrap and process demos passed; coordinator events and driver audit
confirmed that unknown release blocks reassignment, generations advance, stale
writers are rejected, dependencies remain gated and grants do not overlap.
The packed package passed an offline install into a fresh temporary directory,
two-session discovery, message delivery/read, reservation release, and telemetry.

New regressions cover Unicode byte budgeting, complete inbox bodies across pages
and acknowledgements, cursor ownership, task/history paging, query plans,
concurrent observation coalescing, progress beside a stalled driver, lightweight
capability checks, resource/pool name collisions, oversized-event cursor continuity,
worker closure/recreation and a transcript record crossing the
head/tail boundary. Existing ownership, recovery, provider, migration, privacy,
installer and client tests remain in the qualification run.

The repository's seven-job CI matrix additionally runs Node 22/24 on Linux,
macOS and Windows, plus minimum Node 22.16 on Linux. CI receipts are uploaded as
workflow artifacts; raw local benchmark and qualification files live under the
ignored `evidence/optimization-20261114/` directory.

No live agent, GPU workload, installed service, external model endpoint or fleet
configuration was used or changed by this pass. Performance fixtures do not qualify
new deployment environments. Package publication and live rollout are separate work.
