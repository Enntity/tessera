# Changes

## Unreleased

- Fixed: a machine that was answering no longer flashes offline over one missed poll (a Wi-Fi or
  tunnel hiccup). Its last reading holds for up to 10 seconds of misses before it shows offline.
- **Names and addresses from Accord**: a name given to a tile's session in Accord (`accord_title`,
  from Accord's next release) shows as the tile's title unless you named the tile yourself. The
  `board` listing agents read now gives each tile's Accord address and the age of its summary.
  Tessera's agent tools stay read-only.
- ⌘O (and Ask in the top bar) opens a chat with the overseer: an agent in a tile of its own that answers
  for the whole board and directs agents through Accord. A question typed into ⌘K can be put to it.
- + starts a shell at once and lists everything else that can be started beside it. ⌘N is a launcher
  for only what starts something.
- New tiles can start in any folder: type a path or a recent folder's name in the launcher, or pick
  one from the folder shown there. A selected conversation's folder is used the way a terminal's is.
- Fixed: reading Claude Code's `/usage` in the background could leave a finished Claude Code process behind each time, one every ten minutes or so, until Tessera quit. Tessera now waits for every process it starts in a terminal, including one it had to stop.
- Bundle the published Accord 0.6.1 package, including bounded reservation windows, renewal during preparation, coordinator recovery, and installed-version reporting. The dependency lock records the release archive and every bundled file's SHA-256 digest.

## 0.2.0 — source release

- Agents can inspect Fleet resources through CLI/MCP, including owner, queue, expiry and freshness.
- The Needs-you lane separates questions, failures, results to review, and suggested cleanup.
  ⇧⌘J opens one-item triage with keyboard answers, restart, mark-seen and skip actions.
- Devin terminal sessions bind to their live session locks and resume after restart. Animated
  approval prompts are recognized while output continues.
- Fleet job tiles are opt-in; failures, stalled work and leases needing attention remain visible.
- Agent services start at application launch. MCP tool discovery works before the app opens.
- Privacy covers agent API content reads; stale Steward responses are discarded and cleanup
  suggestions are rechecked before closing tiles.
- The integration installer supports Claude Code, Codex and Devin, preserves existing MCP
  registrations and skill backups, and reports path conflicts instead of overwriting real files.
- Source installation, first-run setup, contributor checks, CI packaging, and the signed-release
  procedure are documented. Public binary distribution still requires signing and notarization.
