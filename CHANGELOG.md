# Changes

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
