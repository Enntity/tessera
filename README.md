# Tessera

A mission-control board for AI work. Every running thing — terminals with Claude Code, Codex, Grok,
omp or a plain shell; conversations inside the Claude and Codex desktop apps; any web page — is a
live tile on one full-screen grid. Tiles animate as their content changes and light up when
something finishes or needs you. Click one and it opens full-size right where it was; click outside
and you are back on the board.

Native macOS app, with a focused iOS companion built on the same core.

## What it does

- **Live terminal tiles.** Real PTYs (SwiftTerm). Thumbnails redraw from the terminal buffer at up
  to 10 fps: the whole screen when it fits readably, otherwise its latest output. Any CLI works.
- **Desktop-app sessions as tiles.** Claude desktop Code sessions and Codex desktop threads appear
  automatically, each as its own card with the latest exchange, tool calls and a typing indicator.
  Opening one goes straight to the app, deep-linked to that conversation
  (`claude://code/continue?session=…`, `codex://threads/…`) and snapped where the opened tile would
  sit (Accessibility permission); nothing opens on the board, so you can come back and pick the next
  one. Right-click for Tessera's own transcript (⌘O there goes to the app), or "Continue in Terminal"
  to fork it into a CLI tile.
- **DeepSeek Harness (dsh) sessions as tiles.** Each recent top-level dsh conversation in
  `~/.dsh/sessions` (or `$DSH_HOME`) is its own live card — title, latest messages and tool calls,
  working while a turn runs, *Needs you* on a pending approval (with its reason). Opening one starts
  Tessera's own `dsh web` (via `dsh`, or `npx -y @deepseek-ai/dsh`, which fetches it from npm, on a
  free port with `--no-open`),
  signs the web tile in with its one-time token, and selects that session. The server stops when
  Tessera quits — or crashes.
- **Attention.** Output-then-silence → *Done*. Permission prompts, `(y/n)`, "Do you want to…",
  OSC 9/777 notifications, Claude's own "needs action" turn summaries, and Codex approval events
  → *Needs you*, plus a Dock badge and system notifications while Tessera is in the background.
  ⌘J goes to the next thing that needs you, in one order everywhere (the Needs-you lane, the
  top-bar counters, ⌘K, the iPhone's queue): open questions first, then failures, then results you
  haven't seen, the oldest first.
- **Needs-you lane.** Down the left of the board (⌥⌘\, remembered): that queue as a list, each
  row saying what waits and why — the question itself, `exit 1`, or that it finished — and for how
  long. Click a row to open its tile. Hover a terminal that is asking and the row offers the phone's
  one-tap answers (`1 2 3 y n ⏎`), typed into it without opening it; answered, the row leaves.
  Empty, it says "All caught up".
- **Filter.** Just type on the board (or ⌘F): the board narrows in place, as you type, to the tiles
  whose title, folder, question or error, tab, state, or visible text (a terminal's screen, a
  conversation's latest messages, a page's address) has every word, and lights the words up in
  titles and folders. ⏎ opens the first one, the arrows move among them, Esc shows everything
  again. Chips at the right of the tab strip narrow by state and kind — Needs you, Working,
  Terminals, Claude, Codex, dsh, Web — each with how many tiles it would show; a chip appears only
  while it has something to narrow. Chips of one sort widen each other (Claude or Codex), the two
  sorts and the text narrow each other (Claude, working, "auth"), all within the tab you're on.
- **Watch dock.** ⌘D keeps a tile open beside the board (up to two, stacked, in a column left of
  the accounts): a terminal you can type into, a page, a dsh session's live page, a Claude or
  Codex conversation's transcript, all live while the board carries on. Each has a compact header:
  what it is, its state, its menu, open full size, undock. A terminal or page is in one place at a
  time, so opening a docked tile (a click on it, ⏎, ⌘J, a row in the lane) puts the keyboard in
  its dock panel, whose edge lights up; ⌘W or ⌘⏎ goes back to the board. Its tile on the board wears
  a small mark. A docked terminal is drawn a little smaller, and the dock starts wide enough for
  its 80 columns; drag the dock's edge to resize it. A third tile docked lets the oldest go;
  closing a docked tile undocks it. What is docked and how wide are kept with the board. In a small
  window the accounts, then the lane, make way for it.
- **Tile size.** ⌘- shows more of a busy board at once, ⌘= makes tiles larger, ⌘0 is the standard
  size again: the board scrolls only when tiles would get smaller than the size you chose.
- **Tile states, the same at every size.** Colour means state and nothing else. *Idle*: nothing.
  *Working*: a cyan pill, and a highlight sweeping the line under the header (or the progress the
  program reports, a page's load included). *Needs you*: an amber pill and edge with a glow, and
  the question itself called out on the tile. *Done*, not yet seen: a mint dot after the title and
  a faint edge, nothing moving. *Failed*: a coral pill and edge, and `exit 1` (or the error) in the
  footer. The selected tile has a ring outside its edge, whatever its state. Every tile's footer
  says where it lives (folder or site) and when it last did anything; hover for the full title.
- **Web tiles.** Live, scaled WKWebViews; unread counts in titles (`(3) Inbox`) raise attention.
  A page that doesn't load says why: in its tile's footer, and along the bottom of its open panel.
- **Accounts sidebar.** Remaining balance / plan headroom with one-click top-up: OpenRouter,
  DeepSeek, Moonshot, OpenAI and Anthropic (admin-key spend vs. budget), xAI, ChatGPT/Codex plan
  limits (from local Codex logs), Claude plan limits (opt-in: reads Claude Code's sign-in, never
  modifies it, and falls back to counting your local transcripts), and a custom provider for any
  JSON balance endpoint. Keys live in the login Keychain.
- **Tabs.** All · your own tabs, in a strip over the board. Drag tiles onto a tab (or Move to
  Tab); new tiles land in the tab you're viewing, as does a Claude or Codex app conversation
  started there once its tile appears (a new tile drops the filter, so it always shows); each tab
  shows a count and a dot in the colour of the most pressing thing waiting in it. ⌘1 and ⌘3…9
  switch. The selection is always a tile the board shows. Board commands (Mark All Seen, Close
  Exited, …) act on the tiles on show: the tab being viewed, as filtered.
- **Close with Undo.** Closing a tile never silently destroys work. A toast offers Undo for a few
  seconds, ⌘Z (Edit ▸ Undo Close Tile) brings it back later, and ⌘K lists the last 20 closed tiles
  as "Reopen …", across restarts. A terminal comes back in its folder and, if it ran an agent, in
  the same conversation; a web tile at its address; a hidden Claude or Codex conversation
  reappears. Each returns to its place and tab.
- **Machines.** Top-bar chips for this Mac and any SSH hosts (e.g. DGX Sparks): CPU and GPU load
  over the last minute or two as sparklines, a memory meter that warns as it fills, hottest
  temperature, GPU watts; hover for details, click a remote to open an ssh tile. A tile running
  `ssh` is named after its machine and says so in its footer, in place of the local folder.
- **Shut down & resume.** Quit Tessera (or shut tiles down) and every agent comes back in the same
  conversation — including ones you typed into a shell yourself, and through your own launchers
  (`codex-work` resumes as `codex-work resume <id>`). A tile that is shut down, exited or failed
  opens to a Resume / Restart button (⏎ presses it), never a dead terminal. How:
  - zsh and fish tiles report each command as typed (launchers and aliases included) and when they're
    back at the prompt, via hooks loaded after your own startup files (files untouched; reports carry
    a per-tile secret so printed output can't forge them).
  - Claude Code / Grok started directly get an assigned `--session-id`; otherwise the session file
    the tool writes (same folder, just after start) is matched to the tile. Two agents started in the
    same folder within a minute aren't guessed at.
  - If a resume fails fast (deleted session, older CLI, a launcher with its own session store), the
    tile says so and starts a fresh session instead — you never land on a dead error. If the tool
    isn't found at all (say, after a toolchain switch), the tile shuts down and keeps its
    conversation for Resume.
  - Agents you exited come back as a shell in their last folder. bash tiles resume what Tessera
    launched but don't track commands typed into them; so do other login shells (tcsh, nu, …),
    whose launches run through zsh.
- **Privacy mode (⇧⌘P).** For screenshots and video: terminal and conversation text become
  word-length bars in place, web pages a coarse mosaic. Everything keeps moving.
- **iPhone / iPad.** Pair by scanning the QR code in Settings → iPhone with the Camera. The phone
  gets a "Needs you" queue (in ⌘J's order), live mini tiles, a terminal view (reader mode that
  re-wraps text, or the exact screen with pinch-zoom), one-tap answers (`1 2 3 y n ⏎`, esc, ^C,
  arrows), transcripts, launching, and the accounts panel.

## Mouse and keyboard

Every gesture means the same thing on every kind of tile.

| Gesture | Action |
|---|---|
| Click a tile · ⏎ on the selection | Open it: terminals, web and dsh tiles zoom open in place (a docked one gets the keyboard where it is, in the dock); a Claude or Codex conversation opens in its app. A double-click is a click |
| Click outside the panel · ⌘⏎ · ⌘W | Back to the board; the tile stays selected. From a docked terminal or page too: it stays docked |
| Esc | Back to the board from a transcript or a terminal that has ended. A live terminal or page gets the key itself (agents use it to interrupt) |
| ⌘⏎ (board) | Open the selected tile |
| ⌘W (board) | Close the selected tile, with Undo; a Claude or Codex conversation is only hidden. In another window (Settings), ⌘W closes that window |
| Hover ✕ | Close the tile, with Undo. On a Claude or Codex conversation the button is an eye (Hide): nothing is stopped |
| ⌘Z · Undo in the toast | Bring back the tile just closed or hidden, where it was (in a text field, ⌘Z undoes typing as usual) |
| ←↑→↓ | Move the selection across the grid; it stops at the edges and a scrolling board follows |
| ⌘[ ⌘] | Previous / next tile, round and round. With a tile open, the open tile changes in place (a Claude or Codex conversation shows its transcript; ⌘O goes to the app), passing over docked tiles |
| ⌃Tab | Back to the tile opened before this one; again to return |
| ⌘D | Dock the open or selected tile beside the board, or undock it (also the button on the open panel, and ✕ on a docked tile). Docked from its open panel, a tile keeps the keyboard |
| ⤢ on a docked tile | Open it full size, out of the dock; ⌘D there puts it back |
| Drag the dock's left edge | Make the dock wider or narrower |
| ⌘= / ⌘- / ⌘0 | Larger tiles / smaller tiles, so more fit / the standard size (also in the View menu) |
| Right-click · ⋯ in the open panel or on a docked tile | Open · Open in app / Show Transcript · Continue in Terminal · Dock / Undock · Rename… · Shut Down / Resume · Restart / Reload · Open in Browser · Mark as Seen · Move to Tab · Close / Hide — whichever apply |
| Drag | Reorder tiles; drop one on a tab to file it there, or on the dock to dock it |
| Type on the board · ⌘F | Filter the board in place, as you type. ⏎ opens the first tile found, ←↑→↓ move among those found, Esc shows everything again |
| ⌘K | Find or do anything. Typing finds tiles first — by title, folder, question or error, tab or state (`failed`, `needs`), hidden conversations included — and ⏎ goes to the top one. Below them: Open a URL, New …, the board commands, Reopen … (closed tiles), Run …, Ask Claude / Codex app …, web search. With nothing typed: what can be started, what needs you, and the commands that have something to do |
| ⌘T / ⇧⌘T / ⌥⌘T | New shell / Claude Code / Codex (in the selected tile's folder) |
| ⌘L | New web tile; with a web tile open, its address field |
| ⌘J | The next thing that needs you: questions, then failures, then unseen results, oldest first. Pressed again it moves on from the tile you're on once you have seen it, also when that one opened in its app |
| Needs you · Failed · Done · Working (top bar) | Open the next tile in that state, oldest first (a counter shows only while something is in its state) |
| ⌘1 / ⌘3…9 | All / your tabs |
| ⌘2 | Only what needs you, in the tab you're on (the Needs you chip); again for everything |
| Click a row in the lane | Open that tile, as a click on it does. Hovering a terminal's question: `1 2 3 y n ⏎` answer it in place |
| ⌥⌘\ / ⌘\ | Toggle the Needs-you lane / the accounts sidebar (also in the View menu) |
| ⇧⌘P | Privacy mode |
| ⌥⇧⌘W / ⌥⇧⌘R | Shut down / resume all terminals |
| Board menu · ⌘K | Mark All Seen · Close Exited · Restart Failed · Hide Idle Conversations · Show Hidden Conversations, each for the tab being viewed |

An open panel lists its keys along its bottom edge. New tiles open at once, wherever they come from (⌘T, ⌘L, the palette, a preset, a machine chip,
Continue in Terminal, a link clicked in a terminal). Tabs, the filter and its chips, the top-bar
counters and ⌘1…9 close an open panel before they act. Rename… gives any tile a name of your own, kept with the board; an
empty name goes back to the tile's own title.

## Build and run

Requires macOS 15+ and Xcode 26 (Swift 6 toolchain); the iOS companion needs iOS 17+.

```bash
swift test                          # core tests (parsers, attention, layout, usage APIs, TLS channel)
scripts/build-app.sh                # → .build/app/Tessera.app (release)
open .build/app/Tessera.app
```

`build-app.sh` signs with `$TESSERA_CODESIGN_IDENTITY` (`-` for ad-hoc), or else the first
code-signing identity in your keychain, and prints which. A stable identity keeps macOS permissions
across rebuilds.

On first use macOS asks for: **Accessibility** (to place the Claude/Codex window where a tile
opens), **Notifications** (attention alerts while Tessera is in the background), **Local Network**
(only if you turn on the iPhone link), and a **Keychain** prompt if you add the Claude plan
provider. Everything else is optional and detected: the agent CLIs, the Claude and Codex apps,
dsh, zsh or fish for command tracking, and ssh (plus `nvidia-smi` on GPU hosts) for machine chips.
The SoC temperature on this Mac comes from IOKit's HID sensor SPI, looked up at runtime; if a macOS
update removes it, the chip just omits the temperature.

iOS (needs XcodeGen and the Metal toolchain SwiftTerm's shaders use):

```bash
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain
cd Apps/TesseraIOS && xcodegen generate && open TesseraIOS.xcodeproj
```

Development helpers: `scripts/debug-run.sh <png> "<actions>"` builds a debug copy with its own data
folder, runs scripted actions in it (`launch=cmd;url=…;select=title;open;key=down,return;cmd=k;`
`type=text;click=title;hover=title;chip=claude;dock=title;ctrl=tab;undo;run=closeExited;dump=state.json;shot=now.png;wait=2` — the full
list is in `Sources/TesseraMac/DebugActions.swift`) and writes window captures to the PNG. Its clicks and keys
land while the copy is in the background. A scripted run never opens the Claude or Codex app (it
records what it would have opened), and the copy posts no notifications. With
`TESSERA_DEBUG_HOME=<dir>` its board has none of your own app sessions on it.
`swift scripts/make-icons.swift` regenerates the icons.

## Architecture

```
Sources/
  TesseraKit/     cross-platform (macOS + iOS)
    Core/         models, attention tracker, tile search and the board's filter, grid layout, the
                  dock's and the columns' rules, Keychain
    Terminal/     text/block renderer, snapshot encoder, display-only mirror
    Transcripts/  Claude, Codex and dsh transcript parsers (incremental)
    Usage/        provider request builders and response parsers
    Remote/       wire protocol, TLS-PSK channel + framer, client session
    UI/           design tokens (Style), tile card and its states, thumbnails, conversation view,
                  usage rows
  TesseraHost/    macOS: PTY sessions, desktop-app watcher, window placement,
                  web tiles, usage service, workspace, remote server
  TesseraMac/     the macOS app (SwiftUI)
Apps/TesseraIOS/  the iOS app (XcodeGen project over TesseraKit)
```

The Mac is the host: it owns processes, reads the desktop apps' session stores, and holds secrets.
Remote clients see `TileInfo` for every tile and stream full content only for tiles on screen:
a terminal snapshot (escape-sequence re-creation of the screen plus scrollback) followed by the
live byte stream, which the client feeds into its own SwiftTerm mirror.

**Remote security.** Off by default. TLS with a pre-shared key derived from a 20-character pairing
code (~100 bits); without the code a peer cannot complete the handshake. Anyone with the code can
read and type into your terminals and launch commands, so treat it like an SSH key. Regenerate it
in Settings → iPhone. Over the internet, use Tailscale or a VPN and connect by address.

Network.framework's PSK mode negotiates `TLS_PSK_WITH_AES_128_GCM_SHA256` (no ECDHE), so there is
no forward secrecy: someone who recorded traffic *and* later obtains the code could decrypt it.
Rotating the code limits exposure; an ephemeral X25519 exchange inside the channel is the planned fix.
The host caps paired connections (peers without the code can't take their slots), drops peers that
don't say hello within 10 s, and stops sending to a peer that falls behind, such as a locked phone
(it catches up with fresh state and snapshots once it drains). Pairing links on the phone always
ask first.

## Known limits / next

- Opening a Claude desktop session relies on its `claude://code/continue?session=` deep link.
- The phone reflects the Mac's terminal size; there is no phone-sized re-layout of TUIs.
- No forward secrecy on the remote link yet (see above).
- If you scroll back in a Mac terminal, the phone's snapshot and prompt detection follow the scrolled view.
- No push notifications to the phone yet (needs an APNs relay); the phone updates while open.
- Tiles are one size, stepped for the whole board (⌘= ⌘-); a tile can be docked, not pinned in place.
- A docked terminal takes the dock's size, so the program in it reflows as it is docked and undocked.

## License

MIT; see [LICENSE](LICENSE). Third-party components keep their own licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Tessera is an independent project, not affiliated
with the makers of the tools it works with. Security reports: see [SECURITY.md](SECURITY.md).
