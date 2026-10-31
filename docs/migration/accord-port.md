# Accord port qualification

Accord owns onboarding, identities, discovery, messaging and read state, questions,
operator notifications, session indexing and summaries, overseer rules, reservations,
host connections and sensors. Tessera owns native terminals, windows, browsers,
platform ingestion and transcript rendering, layout, the board brief, notifications,
phone presentation and approved terminal input.

Accord is the only published agent skill. Tessera exposes only native `board`,
`read_tile` and `whoami` tools. Old messaging commands, bridge impersonation routes,
mailbox import and question-ID aliases have been removed. Old skill customizations
move outside discovery. Previous `agent-desk.json` data stays untouched and inactive.
Fresh agent sessions use Accord directly.

## Verified boundary

- The pinned Accord package passed 113 tests and artifact, bootstrap and real
  process-group recovery demos. See `Vendor/accord-lock.json` for package hashes.
- Native input has a durable attempt marker before the terminal effect. A crash
  cannot silently replay it. An uncertain attempt becomes a visible check-in card.
- Native telemetry reads Accord; Swift sensor and SSH probe implementations are removed.
- Fleet reads Accord resources, jobs and manager schedules. LLooM retains existing
  reservation authority. Its imported adapter is read-only; hiding Fleet does not
  delete shared manager state.
- Shared session summaries and command-palette history come from Accord. Steward
  retains the native board brief and presentation suggestions.
- The isolated packaged test installs bundled Accord and Node with system Node
  excluded from PATH. Two enrolled agents exercise discovery, questions, notifications,
  unread state across app restart, shared search, telemetry and removed legacy commands.
- Disabled phone links do not access Keychain. `TESSERA_DATA_DIR` isolates the board,
  preferences and ephemeral test credentials in both debug and release builds.

The final native suite passed 264 tests. The optimized packaged app passed two launches
and restarts after the Keychain isolation fix. Source hashes and check results are recorded
in `qualification.json`.

## Activation and host qualification

Tessera was installed and restarted after the original isolated qualification.
That check missed two live cutover requirements: existing SSH hosts need installed,
linked Accord daemons, and restored CLI transcripts must not count as fresh results.
The original receipt in `qualification.json` describes the pre-activation candidate.
The follow-up repair is recorded in `cutover-repair.json`.

The host cutover installed the qualified standalone Accord package on three hosts
and upgraded the fourth from the earlier qualification build. The upgrade preserved
its authority and four closed claims, with a stopped-state backup and rollback.
All four hosts now provide fresh NVIDIA GPU, temperature, power, and memory readings
through Accord. No GPU workload or reservation was changed. LLooM still owns its
existing serving leases; an overdue lease remains visible until its owner resolves it.

Native host presentation retries unavailable SSH links every 30 seconds and reconciles
SSH aliases with discovered authorities. A future cutover must verify every configured
host in the running UI, including recovery after a transport interruption; a successful
localhost sample alone is insufficient.

Restored agent CLIs baseline their initial transcript replay. Terminal device-query
replies do not count as user input. Approvals, failures, new turns, and active resumed
work still surface. Historical completed sessions arriving from a later source scan
remain quiet; new completions after app launch request review. Automatic overseer
check-ins remain visible as monitoring evidence without becoming human questions.
Actual operator questions continue through Accord's question queue.

The installed Mac Accord service remains at the previously qualified source and epoch.
Its original activation used private consistent SQLite backups, an admission pause,
and zero active claims or external manager requests. Accord is the only published
agent skill. A development signature is not a notarized release.
