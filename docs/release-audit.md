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
- A packaged-app first-launch attempt in an isolated home did not expose an API endpoint before
  its timeout. UI inspection was blocked because the Mac was locked. The cause of that launch
  timeout is not yet established; it is not counted as a passing GUI/onboarding check.
- Existing running Tessera sessions were not restarted or upgraded.

The first baseline build encountered stale compiler paths from a relocated checkout. A fresh
`.build/release-audit` directory resolved that build-environment failure. Packaging also exposed
and fixed Bash 3.2's empty-array behavior under `set -u`.

## Remaining public-release gates

1. Supply a Developer ID Application identity and notarytool profile. The inspected Mac has only
   Apple Development identities. The local ZIP is explicitly named `development`; it is not
   notarized. The public packaging path refuses to produce an asset unless signing, notarization,
   ticket validation, and Gatekeeper checks pass.
2. Unlock the Mac and finish the packaged-app launch investigation and interactive demo checks.
   Test the exact download on a clean user/Mac, including first launch, integration setup, and an
   upgrade preserving state. Automated API tests do not substitute for that installation check.
3. Qualify the particular Fleet head and Steward model used for a live presentation. Existing
   read-only live-board inspection confirmed these integrations are in use locally, but did not
   establish candidate behavior against a new head/model. No live reservations were changed.
4. Review the source changes and CI results before publishing a stable release. The local build
   qualifies Apple silicon only; minimum-OS and Intel compatibility need separate evidence.

[Linux support is tracked separately in issue #7](https://github.com/Enntity/tessera/issues/7).
No Linux implementation was added.
