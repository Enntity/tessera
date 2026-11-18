# Changes

## Unreleased

- Agents can open tiles too: `open_tile` (`tessera open <agent> <cwd>` / `tessera reopen <tile>`)
  starts a shell, claude, codex, devin or omp tile in an existing directory — quietly, without
  touching your view — optionally titled, resumed from a session id, or handed a first prompt
  through the usual wake rules, and brings back a Recently closed tile by id. A per-caller
  hourly cap (Settings → Agents) and an `opens.log` audit trail sit beside `closes.log`, and a
  queued prompt is never typed into a shell's own prompt.
- Agents can tidy the board: `close_tile` (`tessera close <tile> [--force]`) closes an idle tile
  or agent exactly as your own Close does — same toast and Undo — and dismisses a desk card.
  A working, asking or busy tile refuses unless `--force` puts a Close/Don't card on your desk,
  and the overseer's own tile is never closed. Shells running an agent CLI that shell
  integration missed now pick the agent up, so they resume as it.
- Fixed: a wake-approval card no longer makes its target tile look like it is asking (and no
  longer offers the terminal answer keys that would type into it). The card is its own lane row
  with its own choices, and dismissing a tile still clears a real linked session's question.

- Agents can wake an idle agent tile with a prompt: an Accord `native-prompt` delivery (or the new
  `send_to_tile` tool / `tessera send`) is typed at its prompt once it sits idle — never into a
  shell, a busy or asking tile, or one you've just typed into. Settings chooses who may skip the
  approval card (the overseer by default), a tile's menu can make every wake for it ask first, and messages
  for desktop-app conversations offer Open and Copy instead. The tile card shows the message and
  where it got to.
- Fixed: a finished overseer turn no longer lists its tile a second time under To review or
  Can be put away — its own card stands for it — and reading its reply marks the tile seen.
- Hovering an account card now shows its full text, and clicking it opens the provider's account
  page (or Copy Link from its menu).
- Fixed: Accord display names and summaries stopped reaching the board whenever Accord rejected one
  tile's report (its clock can run a fraction of a second behind ours). One bad report no longer
  stalls the sync.
- Fixed: tiles no longer hang silently in shell startup. A tile waits out a macOS folder-permission
  dialog instead of spawning into a blocked open, flags a shell still in its startup files after
  15 seconds, and no longer leaves earlier tiles' PTY masters open in every new shell.
- Fixed: a machine that was answering no longer flashes offline over one missed poll (a Wi-Fi or
  tunnel hiccup). Its last reading holds for up to 10 seconds of misses before it shows offline.
- **Names and addresses from Accord**: a name given to a tile's session in Accord (`accord_title`,
  from Accord's next release) shows as the tile's title unless you named the tile yourself. The
  `board` listing agents read now gives each tile's Accord address and the age of its summary.
  Tessera's agent tools stay read-only.
- ⌘O (and Ask in the top bar) opens a chat with the overseer: an agent in a tile of its own that answers
  for the whole board and directs agents through Accord. A question typed into ⌘K can be put to it.
- The overseer talks from a Tessera card at the top of the Needs-you lane, which opens a pop-up chat
  panel: its Claude transcript rendered as a conversation, tool runs collapsed to one line, and a
  terminal view when it asks for permission. The card, panel and a spinning orb carry an aurora look,
  the overseer tile stays off the grid and out of the board's counts, and replies arriving while the
  panel is open are already read. Conversation panels also break assistant text into markdown blocks:
  lists, headings and fenced code.
- + starts a shell at once and lists everything else that can be started beside it. ⌘N is a launcher
  for only what starts something.
- New tiles can start in any folder: type a path or a recent folder's name in the launcher, or pick
  one from the folder shown there. A selected conversation's folder is used the way a terminal's is.
- Fixed: reading Claude Code's `/usage` in the background could leave a finished Claude Code process behind each time, one every ten minutes or so, until Tessera quit. Tessera now waits for every process it starts in a terminal, including one it had to stop.
- Bundle the published Accord 0.6.9 package, including session display names (`accord_title`), migration-17/18 schema updates, discovery compaction, local resources in `find`, concurrent resource progress, and quieter session checks. The dependency lock records the release archive and every bundled file's SHA-256 digest.

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
