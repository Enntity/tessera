# Tessera 0.2.0 release-readiness audit

Audited on 2026-10-23, starting from `b3b1e85`. The control/communication plane is useful for
local agent coordination, with distinct boundaries: inboxes require polling, LLooM owns resource
reservations, and Steward advises rather than dispatching work.

Status: **development candidate prepared; public distribution not yet qualified**.

## Findings and changes

| Area | Finding | Change / outcome |
| --- | --- | --- |
| Resource coordination | Fleet leases were visible in the UI but absent from agent tools | Added CLI/MCP `resources`, with owners, queue, expiry, fetch time, and stale/unconfigured states |
| MCP onboarding | A client starting before the app could initialize but could not discover tools | Shared tool catalog supports discovery offline; calls still require the app |
| API robustness | Negative Content-Length could form an invalid range before authentication; oversized numeric arguments and scalar caller metadata were unsafe | Validate request lengths, numeric conversion, and caller shape; bound incomplete connections |
| Privacy | Board summaries and identity bypassed the tile-read privacy check | Gate content reads, recheck pending reads, redact titles/folders/briefs/inboxes/answers; create credential files with restrictive permissions before rename |
| Steward lifecycle | Old completions could restore results after configuration changed or Steward was disabled | Discard stale/disabled/paused responses and reset cached summaries |
| Steward actions | A cleanup suggestion could remain after a tile became active | Recheck current state at display and click time; protect working, waiting, and unseen tiles |
| Delivery clarity | Rejected typing to a desktop tile incorrectly claimed inbox delivery | Report that nothing was sent and explain the inbox-only retry |
| Agent setup | Installation could replace customized skills, silently retain an unrelated executable, and block the UI | Preserve backups, report conflicts/failures, drain subprocess output, install off the UI thread |
| Presentation | Coordination features had no focused setup/reference/demo guide | Added control-plane, install, release, and demo guides plus launch copy; README leads with coordination |
| Distribution | No packaged release or CI workflow | Added macOS CI, isolated installer tests, ZIP/checksum packaging, and a gated notarization path |
| Build portability | Xcode 26.0 CI could not type-check a long command-palette array expression | Split it into explicit appends while retaining ordering |
| Startup | Agent services started from the board's `onAppear`; an unlocked launch could stay idle until the UI appeared | Start from `applicationDidFinishLaunching`, with the model owned by the app delegate; add a packaged startup/restart regression |

## Verification

- Clean baseline: 236 tests passed.
- Expanded full suite: 242 tests passed, zero failures, on Apple silicon/macOS 26.5.1 with Xcode
  26.6. Tests cover real CLI/MCP loopback requests, authentication/browser rejection, message
  exchange and answers, privacy refusals, resource freshness, malformed inputs, a held Steward
  response after disable, PTYs, persistence, and remote channels.
- Final caller-shape edit: the focused AgentAPITests suite passed after the full run.
- The real installer passed in a temporary home: dry-run, command/skill setup, stubbed Claude MCP
  registration, Codex config preservation, backups, repeat installation, and real-file conflict
  refusal. The bundled command also passed this test after ZIP extraction.
- Release app and bundled CLI built; the extracted app passed `codesign --verify --deep --strict`.
- Shell syntax and `git diff --check` passed.
- The startup delay reproduced on the unlocked desktop. A process sample showed an idle main
  run loop; activating the board brought up the API. Startup had been tied to the board's
  `onAppear` callback. After moving it to the app launch event, the packaged app exposed its API
  in 5.1 seconds on first launch and 2.2 seconds on restart, without UI interaction. The added
  `scripts/test-packaged-app.py` checks both launches, restored terminals, caller identity,
  durable/read-once inbox delivery, endpoint credential replacement and mode 0600, unconfigured
  resources, a question, and a note.
- A first run from a fresh extraction path exceeded the initial 15-second test deadline. With a
  longer observation window, that exact archive passed without UI interaction: 26.3 seconds on
  cold launch, 2.5 seconds on restart. The smoke test now allows 60 seconds and prints the actual
  duration. This establishes liveness, not consistently fast startup; the cause of the cold-path
  delay remains unconfirmed and timing must be checked again on the signed download.
- Interactive packaged-app checks passed in a disposable home: two terminal tiles, a question
  answered in the Needs-you lane and retrieved by CLI, approval-gated `--type` delivery verified
  in the terminal, privacy refusing a board read, and the Settings installer completing without
  blocking the UI. The installed command, skill, and Codex MCP configuration were verified;
  Claude registration used a stub to protect the user's existing client setup. A normal app quit
  saved both tiles, and the updated build restored them with the unread inbox message intact.
- The candidate reached the configured live Fleet and Steward endpoints, which returned 401
  because the disposable home could not locate the user's saved keys. This verifies visible
  failure handling, not a successful live integration. No keys or reservations were changed.
- Existing running Tessera sessions were not restarted or upgraded.

The first baseline build encountered stale compiler paths from a relocated checkout. A fresh
`.build/release-audit` directory resolved that build-environment failure. Packaging also exposed
and fixed Bash 3.2's empty-array behavior under `set -u`.

## Remaining public-release gates

1. Supply a Developer ID Application identity and notarytool profile. The inspected Mac has only
   Apple Development identities. The local ZIP is explicitly named `development`; it is not
   notarized. The public packaging path refuses to produce an asset unless signing, notarization,
   ticket validation, and Gatekeeper checks pass.
2. Repeat installation from the final signed/notarized download on a clean user/Mac. Local
   packaged launch, UI, installer, and state-preserving update checks now pass in an isolated
   home on this Mac. They do not establish downloaded Gatekeeper behavior or another OS version.
   Check cold-launch latency as well as eventual startup.
3. Qualify the particular Fleet head and Steward model used for a live presentation. Existing
   read-only live-board inspection confirmed these integrations are in use locally, but did not
   establish candidate behavior against a new head/model. No live reservations were changed.
4. Review the source changes and CI results before publishing a stable release. The local build
   qualifies Apple silicon only; minimum-OS and Intel compatibility need separate evidence.

[Linux support is tracked separately in issue #7](https://github.com/Enntity/tessera/issues/7).
No Linux implementation was added.
