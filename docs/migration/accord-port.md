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

## Activation boundary

The candidate is built separately. The installed Tessera app has not been replaced
or restarted, and active terminals have not been interrupted. Packaged checks use a
private host and dynamic loopback ports; they do not replace the live launchd service.
No LLooM serving workload, Spark daemon or Shrug lifecycle controller was changed.
A development signature is not a notarized release.

The installed Accord service was separately activated at epoch 11 after source-hash checks,
private consistent SQLite backups, an admission pause and zero active claims or external
manager requests. Its prior admission state was restored. The installed Accord skill was
refreshed and Tessera skill copies were archived outside agent discovery.
