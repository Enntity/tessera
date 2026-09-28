# Tessera

A mission-control board for AI work. Every running thing — terminals with Claude Code, Codex, Grok,
omp or a plain shell; conversations inside the Claude and Codex desktop apps; any web page — is a
live tile on one full-screen grid. Tiles animate as their content changes and light up when
something finishes or needs you. Click one and it opens full-size right where it was.

Native macOS app, with a focused iOS companion built on the same core.

## What it does

- **Live terminal tiles.** Real PTYs (SwiftTerm). Thumbnails redraw from the terminal buffer at up
  to 10 fps: a colored minimap when small, real text when there's room. Any CLI works.
- **Desktop-app sessions as tiles.** Claude desktop Code sessions and Codex desktop threads appear
  automatically, each as its own card with the latest exchange, tool calls and a typing indicator.
  Opening one snaps the real app window onto the tile's rectangle (Accessibility permission) and
  deep-links to that conversation (`claude://code/continue?session=…`, `codex://threads/…`).
  "Continue in Terminal" forks it into a CLI tile.
- **Attention.** Output-then-silence → *Done* (green breathing ring). Permission prompts, `(y/n)`,
  "Do you want to…", OSC 9/777 notifications, Claude's own "needs action" turn summaries, and
  Codex approval events → *Needs you* (amber comet ring), plus a Dock badge and system
  notifications while Tessera is in the background. ⌘J jumps to the next one.
- **Web tiles.** Live, scaled WKWebViews; unread counts in titles (`(3) Inbox`) raise attention.
- **Accounts sidebar.** Remaining balance / plan headroom with one-click top-up: OpenRouter,
  DeepSeek, Moonshot, OpenAI and Anthropic (admin-key spend vs. budget), xAI, ChatGPT/Codex plan
  limits (from local Codex logs), Claude plan limits (opt-in, uses Claude Code's sign-in), and a
  custom provider for any JSON balance endpoint. Keys live in the login Keychain.
- **HUD.** Counts of working / done / needs-you, filters, CPU and memory sparkline, clock.
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
| ⌥⌘1…5 | Filter: all, needs you, terminals, apps, web |
| ⌘\ | Toggle the accounts sidebar |
| ⌘W | Close tile |

Esc inside an open terminal goes to the program (agents use it to interrupt), so use ⌘⏎ there.

## Build and run

Requires Xcode 26 (Swift 6 toolchain).

```bash
swift test                          # core tests (parsers, attention, layout, usage APIs, TLS channel)
scripts/build-app.sh                # → .build/app/Tessera.app (release, signed with your first identity)
open .build/app/Tessera.app
```

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
    Terminal/     minimap/text renderer, snapshot encoder, display-only mirror
    Transcripts/  Claude + Codex JSONL parsers (incremental)
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
The host caps connections, drops peers that don't say hello within 10 s, and stops streaming to a
peer that falls behind (it resyncs with a snapshot). Pairing links on the phone always ask first.

## Known limits / next

- Opening a Claude desktop session relies on its `claude://code/continue?session=` deep link.
- The phone reflects the Mac's terminal size; there is no phone-sized re-layout of TUIs.
- No forward secrecy on the remote link yet (see above).
- If you scroll back in a Mac terminal, the phone's snapshot and prompt detection follow the scrolled view.
- No push notifications to the phone yet (needs an APNs relay); the phone updates while open.
- Tile order persists; tile sizes are uniform (no pinning/resizing yet).
