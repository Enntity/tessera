# Tessera

A mission-control board for AI work. Every running thing — terminals with Claude Code, Codex, Grok,
omp or a plain shell; conversations inside the Claude and Codex desktop apps; any web page — is a
live tile on one full-screen grid. Tiles animate as their content changes and light up when
something finishes or needs you. Click one and it opens full-size right where it was.

Native macOS app, with a focused iOS companion built on the same core.

## What it does

- **Live terminal tiles.** Real PTYs (SwiftTerm). Thumbnails redraw from the terminal buffer at up
  to 10 fps: the whole screen when it fits readably, otherwise its latest output. Any CLI works.
- **Desktop-app sessions as tiles.** Claude desktop Code sessions and Codex desktop threads appear
  automatically, each as its own card with the latest exchange, tool calls and a typing indicator.
  Opening one goes straight to the app, deep-linked to that conversation
  (`claude://code/continue?session=…`, `codex://threads/…`) and snapped where the opened tile would
  sit (Accessibility permission); nothing opens on the board, so you can come back and pick the next
  one. Right-click for Tessera's own transcript, or "Continue in Terminal" to fork it into a CLI tile.
- **DeepSeek Harness (dsh) sessions as tiles.** Each recent top-level dsh conversation in
  `~/.dsh/sessions` (or `$DSH_HOME`) is its own live card — title, latest messages and tool calls,
  working while a turn runs, *Needs you* on a pending approval (with its reason). Opening one starts
  Tessera's own `dsh web` (via `dsh`, or `npx -y @deepseek-ai/dsh`, which fetches it from npm, on a
  free port with `--no-open`),
  signs the web tile in with its one-time token, and selects that session. The server stops when
  Tessera quits — or crashes.
- **Attention.** Output-then-silence → *Done* (green breathing ring). Permission prompts, `(y/n)`,
  "Do you want to…", OSC 9/777 notifications, Claude's own "needs action" turn summaries, and
  Codex approval events → *Needs you* (amber comet ring), plus a Dock badge and system
  notifications while Tessera is in the background. ⌘J jumps to the next one.
- **Web tiles.** Live, scaled WKWebViews; unread counts in titles (`(3) Inbox`) raise attention.
- **Accounts sidebar.** Remaining balance / plan headroom with one-click top-up: OpenRouter,
  DeepSeek, Moonshot, OpenAI and Anthropic (admin-key spend vs. budget), xAI, ChatGPT/Codex plan
  limits (from local Codex logs), Claude plan limits (opt-in: reads Claude Code's sign-in, never
  modifies it, and falls back to counting your local transcripts), and a custom provider for any
  JSON balance endpoint. Keys live in the login Keychain.
- **Tabs.** All · Needs you · your own tabs. Drag tiles onto a tab (or Move to Tab); new tiles land
  in the tab you're viewing; each tab shows a count and an attention dot. ⌘1…9 switch.
- **Machines.** Top-bar chips for this Mac and any SSH hosts (e.g. DGX Sparks): CPU / GPU / memory
  bars, hottest temperature, GPU watts; hover for details, click a remote to open an ssh tile.
- **Shut down & resume.** Quit Tessera (or shut tiles down) and every agent comes back in the same
  conversation — including ones you typed into a shell yourself, and through your own launchers
  (`codex-work` resumes as `codex-work resume <id>`). How:
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
  gets a "Needs you" queue, live mini tiles, a terminal view (reader mode that re-wraps text, or
  the exact screen with pinch-zoom), one-tap answers (`1 2 3 y n ⏎`, esc, ^C, arrows), transcripts,
  launching, and the accounts panel.

## Keyboard

| Keys | Action |
|---|---|
| ⌘K | Command palette: launch agents, run commands, open URLs, jump to tiles |
| ⌘T / ⇧⌘T / ⌥⌘T | New shell / Claude Code / Codex (in the selected tile's folder) |
| ⌘L | New web tile |
| ←↑→↓, ⏎ | Move selection, open tile |
| ⌘⏎, Esc (board) | Open / close tile |
| ⌘[ ⌘] | Previous / next tile |
| ⌘J | Next tile that needs you |
| ⌘1 / ⌘2 / ⌘3…9 | All / Needs you / your tabs |
| ⌘\ | Toggle the accounts sidebar |
| ⇧⌘P | Privacy mode |
| ⌥⇧⌘W / ⌥⇧⌘R | Shut down / resume all terminals |
| ⌘W | Close tile |

Esc inside an open terminal goes to the program (agents use it to interrupt), so use ⌘⏎ there.

## Build and run

Requires macOS 14+ and Xcode 26 (Swift 6 toolchain); the iOS companion needs iOS 17+.

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

Development helpers: `scripts/debug-run.sh <png> "<actions>"` builds, launches with scripted
actions (`launch=cmd;url=…;open=terminal|app|web;palette;remote;wait=2`) and writes window
captures to the PNG. `swift scripts/make-icons.swift` regenerates the icons.

## Architecture

```
Sources/
  TesseraKit/     cross-platform (macOS + iOS)
    Core/         models, attention tracker, grid layout, Keychain
    Terminal/     text/block renderer, snapshot encoder, display-only mirror
    Transcripts/  Claude, Codex and dsh transcript parsers (incremental)
    Usage/        provider request builders and response parsers
    Remote/       wire protocol, TLS-PSK channel + framer, client session
    UI/           tile card, glows, thumbnails, conversation view, usage rows
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
- Tile order persists; tile sizes are uniform (no pinning/resizing yet).

## License

MIT; see [LICENSE](LICENSE). Third-party components keep their own licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Tessera is an independent project, not affiliated
with the makers of the tools it works with. Security reports: see [SECURITY.md](SECURITY.md).
