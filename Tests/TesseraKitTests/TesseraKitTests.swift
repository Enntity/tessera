import Observation
import SwiftTerm
import XCTest
@testable import TesseraHost
@testable import TesseraKit

final class GridLayoutTests: XCTestCase {
    func testSingleTileFillsWidthOrHeight() {
        let g = GridLayout.fit(count: 1, in: CGSize(width: 1600, height: 1000), spacing: 0)
        XCTAssertEqual(g.columns, 1)
        XCTAssertEqual(g.tileSize.width, 1600, accuracy: 0.5)
    }

    func testManyTilesPreferWideGridOnWideScreen() {
        let g = GridLayout.fit(count: 24, in: CGSize(width: 5000, height: 2000), spacing: 10)
        XCTAssertGreaterThanOrEqual(g.columns, 6)
        XCTAssertFalse(g.scrolls)
        XCTAssertLessThanOrEqual(g.contentHeight, 2000)
    }

    func testFallsBackToScrollingAtMinimumWidth() {
        let g = GridLayout.fit(count: 200, in: CGSize(width: 1000, height: 600), spacing: 10, minTileWidth: 200)
        XCTAssertTrue(g.scrolls)
        XCTAssertGreaterThanOrEqual(g.tileSize.width, 200)
    }

    func testGridStartsAtTheTopCentredAcross() {
        // 810 wide in 1000: the room left over is shared across, and all of it is below.
        let area = CGSize(width: 1000, height: 1000)
        let grid = GridLayout(columns: 2, rows: 2, tileSize: CGSize(width: 400, height: 250), spacing: 10, scrolls: false)
        XCTAssertEqual(grid.origin(of: 0, in: area), CGPoint(x: 95, y: 0))
        XCTAssertEqual(grid.origin(of: 1, in: area), CGPoint(x: 505, y: 0))
        XCTAssertEqual(grid.origin(of: 2, in: area), CGPoint(x: 95, y: 260))
        let scrolling = GridLayout.fit(count: 200, in: CGSize(width: 1000, height: 600), spacing: 10, minTileWidth: 200)
        XCTAssertTrue(scrolling.scrolls)
        XCTAssertEqual(scrolling.origin(of: 0, in: CGSize(width: 1000, height: 600)).y, 0)
        XCTAssertEqual(scrolling.origin(of: scrolling.columns, in: CGSize(width: 1000, height: 600)).y,
                       scrolling.tileSize.height + 10, accuracy: 0.5)
    }

    func testExpandedFrameStaysCenteredOnTileAndInsideBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let mid = GridLayout.expandedFrame(from: CGRect(x: 900, y: 500, width: 200, height: 120), in: bounds, preferred: CGSize(width: 1000, height: 700))
        XCTAssertEqual(mid.midX, 1000, accuracy: 0.5)
        XCTAssertEqual(mid.midY, 560, accuracy: 0.5)
        let corner = GridLayout.expandedFrame(from: CGRect(x: 1850, y: 1100, width: 150, height: 100), in: bounds, preferred: CGSize(width: 1000, height: 700))
        XCTAssertEqual(corner.maxX, 2000, accuracy: 0.5)
        XCTAssertEqual(corner.maxY, 1200, accuracy: 0.5)
    }
}

/// Arrow keys on the board: the real columns, no wrap-around, and the view follows.
final class GridNavigationTests: XCTestCase {
    // Seven tiles in three columns:  0 1 2 / 3 4 5 / 6
    let grid = GridLayout(columns: 3, rows: 3, tileSize: CGSize(width: 100, height: 60), spacing: 10, scrolls: true)

    private func move(_ move: GridMove, from index: Int?) -> Int? { grid.index(moving: move, from: index, count: 7) }

    func testArrowsFollowTheColumnsAndStopAtTheEdges() {
        XCTAssertEqual(move(.down, from: 1), 4)
        XCTAssertEqual(move(.up, from: 4), 1)
        XCTAssertEqual(move(.right, from: 2), 3)
        XCTAssertEqual(move(.left, from: 3), 2)
        // No wrap-around: the edges hold.
        XCTAssertNil(move(.up, from: 1))
        XCTAssertNil(move(.down, from: 6))
        XCTAssertNil(move(.left, from: 0))
        XCTAssertNil(move(.right, from: 6))
    }

    func testDownAboveAShortLastRowLandsOnItsLastTile() {
        XCTAssertEqual(move(.down, from: 3), 6)
        XCTAssertEqual(move(.down, from: 5), 6)
        // One column: two stacked tiles are one step apart.
        let stacked = GridLayout(columns: 1, rows: 2, tileSize: .zero, spacing: 10, scrolls: false)
        XCTAssertEqual(stacked.index(moving: .down, from: 0, count: 2), 1)
        XCTAssertNil(stacked.index(moving: .down, from: 1, count: 2))
    }

    func testPreviousAndNextGoRoundEveryTile() {
        XCTAssertEqual(move(.next, from: 6), 0)
        XCTAssertEqual(move(.previous, from: 0), 6)
        XCTAssertEqual(move(.next, from: 2), 3)
    }

    func testWithNothingSelectedAMoveStartsAtAnEnd() {
        XCTAssertEqual(move(.right, from: nil), 0)
        XCTAssertEqual(move(.down, from: nil), 0)
        XCTAssertEqual(move(.next, from: nil), 0)
        XCTAssertEqual(move(.previous, from: nil), 6)
        XCTAssertNil(grid.index(moving: .next, from: nil, count: 0))
        // A selection that is no longer there counts as none.
        XCTAssertEqual(move(.left, from: 9), 0)
    }

    func testScrollFollowsOnlyAsFarAsNeeded() {
        // Rows at 0, 70 and 140; 200 of content in a 100-tall view.
        XCTAssertEqual(grid.scrollOffset(showing: 0, height: 100, current: 0), 0)
        XCTAssertEqual(grid.scrollOffset(showing: 4, height: 100, current: 0), 30)
        XCTAssertEqual(grid.scrollOffset(showing: 6, height: 100, current: 0), 100)
        XCTAssertEqual(grid.scrollOffset(showing: 1, height: 100, current: 100), 0)
        // Already in view: nothing moves.
        XCTAssertEqual(grid.scrollOffset(showing: 4, height: 100, current: 50), 50)
        let fits = GridLayout.fit(count: 4, in: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(fits.scrollOffset(showing: 3, height: 1000, current: 0), 0)
    }
}

final class TerminalActivityTrackerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testSustainedOutputThenSilenceIsDoneWithAttention() {
        var t = TerminalActivityTracker()
        for i in 0..<30 { t.noteOutput(bytes: 400, at: t0.addingTimeInterval(Double(i) * 0.1)) }
        t.tick(now: t0.addingTimeInterval(3.0), screenTail: [])
        XCTAssertEqual(t.activity, .working)
        t.tick(now: t0.addingTimeInterval(5.0), screenTail: ["$ "])
        XCTAssertEqual(t.activity, .done)
        XCTAssertTrue(t.attention)
        t.acknowledge()
        XCTAssertEqual(t.activity, .idle)
        XCTAssertFalse(t.attention)
    }

    func testUnseenResultOutlastsABlipOfOutput() {
        var t = TerminalActivityTracker()
        for i in 0..<30 { t.noteOutput(bytes: 400, at: t0.addingTimeInterval(Double(i) * 0.1)) }
        t.tick(now: t0.addingTimeInterval(3.0), screenTail: [])
        t.tick(now: t0.addingTimeInterval(5.0), screenTail: ["$ "])
        XCTAssertEqual(t.activity, .done)
        t.noteOutput(bytes: 80, at: t0.addingTimeInterval(8))
        t.tick(now: t0.addingTimeInterval(8.1), screenTail: ["$ "])
        XCTAssertEqual(t.activity, .working)
        XCTAssertTrue(t.attention)
        t.tick(now: t0.addingTimeInterval(10), screenTail: ["$ "])
        XCTAssertEqual(t.activity, .done)
        XCTAssertTrue(t.attention)
    }

    func testClearedPromptLeavesNothingWaiting() {
        var t = TerminalActivityTracker()
        t.noteOutput(bytes: 100, at: t0)
        t.tick(now: t0.addingTimeInterval(2), screenTail: ["Do you want to proceed? (y/n)"])
        XCTAssertTrue(t.attention)
        t.tick(now: t0.addingTimeInterval(3), screenTail: ["$ "])
        XCTAssertEqual(t.activity, .idle)
        XCTAssertFalse(t.attention)
    }

    func testOnlyAttentionStatesNeedTheUser() {
        var tile = TileInfo(id: "t", kind: .terminal, flavor: .shell, title: "t", activity: .working, attention: true)
        XCTAssertFalse(tile.isUnseen)
        XCTAssertFalse(tile.needsUser)
        tile.activity = .done
        XCTAssertTrue(tile.needsUser)
        tile.attention = false
        XCTAssertFalse(tile.needsUser)
        tile.activity = .needsInput
        XCTAssertTrue(tile.needsUser)
    }

    func testClosingAnAppConversationOnlyHidesIt() {
        XCTAssertEqual(TileKind.terminal.closeLabel, "Close")
        XCTAssertEqual(TileKind.browser.closeLabel, "Close")
        XCTAssertEqual(TileKind.agentSession.closeLabel, "Hide")
        XCTAssertNotEqual(TileKind.agentSession.closeSymbol, TileKind.terminal.closeSymbol)
    }

    func testShortBurstIsQuietlyIdle() {
        var t = TerminalActivityTracker()
        t.noteOutput(bytes: 2000, at: t0)
        t.tick(now: t0.addingTimeInterval(0.2), screenTail: [])
        t.tick(now: t0.addingTimeInterval(3), screenTail: ["$ "])
        XCTAssertEqual(t.activity, .idle)
        XCTAssertFalse(t.attention)
    }

    func testPermissionPromptIsNeedsInput() {
        var t = TerminalActivityTracker()
        t.noteOutput(bytes: 500, at: t0)
        let screen = ["│ Bash command", "│   rm -rf build", "│ Do you want to proceed?", "│ ❯ 1. Yes", "│   2. No"]
        t.tick(now: t0.addingTimeInterval(2), screenTail: screen)
        XCTAssertEqual(t.activity, .needsInput)
        XCTAssertTrue(t.attention)
        XCTAssertNotNil(t.detail)
    }

    func testAnsweredPromptDoesNotReRaise() {
        var t = TerminalActivityTracker()
        t.noteOutput(bytes: 100, at: t0)
        let asking = ["$ read -q", "Do you want to proceed? (y/n)"]
        t.tick(now: t0.addingTimeInterval(2), screenTail: asking)
        XCTAssertEqual(t.activity, .needsInput)
        t.noteInput(at: t0.addingTimeInterval(3))
        t.noteOutput(bytes: 40, at: t0.addingTimeInterval(3.1))
        let answered = ["$ read -q", "Do you want to proceed? (y/n) y approved", "$"]
        t.tick(now: t0.addingTimeInterval(6), screenTail: answered)
        XCTAssertNotEqual(t.activity, .needsInput)
        // Once it scrolls away, a fresh identical question counts again.
        t.tick(now: t0.addingTimeInterval(7), screenTail: ["$"])
        t.noteOutput(bytes: 40, at: t0.addingTimeInterval(8))
        t.tick(now: t0.addingTimeInterval(10), screenTail: asking)
        XCTAssertEqual(t.activity, .needsInput)
    }

    func testSpinnerTextKeepsWorkingEvenWhenQuiet() {
        var t = TerminalActivityTracker()
        t.noteOutput(bytes: 500, at: t0)
        t.tick(now: t0.addingTimeInterval(5), screenTail: ["✻ Cogitating… (12s · esc to interrupt)"])
        XCTAssertEqual(t.activity, .working)
    }

    func testEchoDoesNotCountAsWork() {
        var t = TerminalActivityTracker()
        t.noteOutput(bytes: 10, at: t0)
        t.tick(now: t0.addingTimeInterval(2), screenTail: ["$ "])
        t.noteInput(at: t0.addingTimeInterval(10))
        t.noteOutput(bytes: 1, at: t0.addingTimeInterval(10.05))
        t.tick(now: t0.addingTimeInterval(10.1), screenTail: ["$ l"])
        XCTAssertEqual(t.activity, .idle)
    }

    func testViewedTileDoesNotRaiseAttention() {
        var t = TerminalActivityTracker()
        t.isBeingViewed = true
        t.noteNotification(title: "Claude Code", body: "Claude is waiting for your input")
        XCTAssertFalse(t.attention)
        XCTAssertEqual(t.activity, .needsInput)
    }

    func testSilentProgramSettlesToIdle() {
        var t = TerminalActivityTracker()
        t.tick(now: t0, screenTail: [])
        XCTAssertEqual(t.activity, .starting)
        t.tick(now: t0.addingTimeInterval(2), screenTail: [])
        XCTAssertEqual(t.activity, .idle)
    }

    func testSpinnerGlyphsLeaveTitles() {
        XCTAssertEqual(TerminalSession.cleanTitle("⠂ Respond to greeting | ml"), "Respond to greeting | ml")
        XCTAssertEqual(TerminalSession.cleanTitle("✳ Claude Code"), "Claude Code")
        XCTAssertEqual(TerminalSession.cleanTitle("~/src/app"), "~/src/app")
    }

    /// The flavor picks a tile's colour, glyph and resume behaviour; launchers count as their tool.
    func testFlavorFromCommand() {
        let cases: [(String?, AgentFlavor)] = [
            ("claude", .claude), ("codex-work", .codex), ("FOO=1 grok", .grok), ("/opt/bin/gemini -p x", .gemini),
            ("dsh", .dsh), ("zsh", .shell), ("npm test", .custom), (nil, .shell)
        ]
        for (command, flavor) in cases { XCTAssertEqual(AgentFlavor.infer(fromCommand: command), flavor, command ?? "nil") }
    }

    func testMarkdownPreviewRendersInlineAndDropsHeadings() {
        let a = "# Audit\n**Normal mode:** uses `crop` now".markdownPreview(200)
        XCTAssertEqual(String(a.characters), "Audit Normal mode: uses crop now")
    }

    func testWaitStatusDecoding() {
        XCTAssertEqual(TerminalSession.exitCode(fromWaitStatus: 256), 1)
        XCTAssertEqual(TerminalSession.exitCode(fromWaitStatus: 0), 0)
        XCTAssertEqual(TerminalSession.exitCode(fromWaitStatus: 9), 137)
    }

    func testProgramThatNeverStartedIsAFailure() {
        var t = TerminalActivityTracker()
        t.noteExit(code: nil, failure: "Couldn't start zsh")
        XCTAssertEqual(t.activity, .failed)
        XCTAssertEqual(t.detail, "Couldn't start zsh")
        XCTAssertTrue(t.attention)
        t.restart()
        t.noteExit(code: nil)
        XCTAssertEqual(t.activity, .exited)
    }

    func testFailedExitRaisesAttention() {
        var t = TerminalActivityTracker()
        t.noteExit(code: 2)
        XCTAssertEqual(t.activity, .failed)
        XCTAssertTrue(t.attention)
        // Short enough for a tile's footer.
        XCTAssertEqual(t.detail, "exit 2")
        t.restart()
        t.noteExit(code: 0)
        XCTAssertEqual(t.activity, .exited)
        XCTAssertEqual(t.detail, "Exited")
    }
}

final class TranscriptParserTests: XCTestCase {
    func testClaudeTurnLifecycle() {
        var p = ClaudeTranscriptParser()
        p.ingest(text: """
        {"type":"custom-title","customTitle":"Fix login"}
        {"type":"user","uuid":"u1","timestamp":"2026-09-28T10:00:00.000Z","message":{"role":"user","content":"Fix the login bug"}}
        {"type":"user","uuid":"u0","isMeta":true,"timestamp":"2026-09-28T10:00:00.000Z","message":{"role":"user","content":"<command-name>/clear</command-name>"}}
        {"type":"assistant","uuid":"a1","timestamp":"2026-09-28T10:00:05.000Z","message":{"model":"claude-opus-5-5","stop_reason":"tool_use","content":[{"type":"text","text":"Looking."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"npm test"}}],"usage":{"input_tokens":10,"cache_read_input_tokens":1000}}}
        """)
        let now = ISO8601DateFormatter().date(from: "2026-09-28T10:00:15Z")!
        var s = p.snapshot(now: now)
        XCTAssertEqual(p.title, "Fix login")
        XCTAssertEqual(s.activity, .working)
        XCTAssertEqual(s.detail?.hasPrefix("Running Bash"), true)
        XCTAssertEqual(s.contextTokens, 1010)
        XCTAssertEqual(s.items.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(s.items.last?.text, "npm test")

        p.ingest(text: """
        {"type":"user","uuid":"u2","timestamp":"2026-09-28T10:00:20.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}
        {"type":"assistant","uuid":"a2","timestamp":"2026-09-28T10:00:25.000Z","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Fixed."}]}}
        """)
        s = p.snapshot(now: now.addingTimeInterval(30))
        XCTAssertEqual(s.activity, .done)
        XCTAssertEqual(s.items.last?.text, "Fixed.")
    }

    func testRunningToolAndStaleTurns() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(TranscriptSupport.running("Bash"), "Running Bash")
        XCTAssertEqual(TranscriptSupport.openTurnActivity(lastEventAt: now.addingTimeInterval(-60), now: now, staleAfter: 600), .working)
        XCTAssertEqual(TranscriptSupport.openTurnActivity(lastEventAt: now.addingTimeInterval(-601), now: now, staleAfter: 600), .idle)
        XCTAssertEqual(TranscriptSupport.openTurnActivity(lastEventAt: nil, now: now, staleAfter: 600), .idle)
    }

    func testRunningToolSnapshotsHoldStillBetweenScans() {
        let now = ISO8601DateFormatter().date(from: "2026-09-28T10:00:10Z")!
        var claude = ClaudeTranscriptParser()
        claude.ingest(text: """
        {"type":"assistant","uuid":"a1","timestamp":"2026-09-28T10:00:05.000Z","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"make"}}]}}
        """)
        XCTAssertEqual(claude.snapshot(now: now).detail, "Running Bash")
        XCTAssertEqual(claude.snapshot(now: now), claude.snapshot(now: now.addingTimeInterval(7)))
        var codex = CodexTranscriptParser()
        codex.ingest(text: """
        {"timestamp":"2026-09-28T10:00:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t"}}
        {"timestamp":"2026-09-28T10:00:02.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{}","call_id":"c1"}}
        """)
        XCTAssertEqual(codex.snapshot(now: now).detail, "Running exec_command")
        XCTAssertEqual(codex.snapshot(now: now), codex.snapshot(now: now.addingTimeInterval(7)))
    }

    func testClaudeStalledEditIsNeedsInput() {
        var p = ClaudeTranscriptParser()
        p.ingest(text: """
        {"type":"assistant","uuid":"a1","timestamp":"2026-09-28T10:00:05.000Z","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/x.swift"}}]}}
        """)
        let s = p.snapshot(now: ISO8601DateFormatter().date(from: "2026-09-28T10:01:00Z")!)
        XCTAssertEqual(s.activity, .needsInput)
    }

    func testCodexTurnAndApproval() {
        var p = CodexTranscriptParser()
        p.ingest(text: """
        {"timestamp":"2026-09-28T10:00:00.000Z","type":"session_meta","payload":{"id":"abc","cwd":"/tmp/x","originator":"Codex Desktop"}}
        {"timestamp":"2026-09-28T10:00:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t"}}
        {"timestamp":"2026-09-28T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /tmp"}]}}
        {"timestamp":"2026-09-28T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Ship it"}]}}
        {"timestamp":"2026-09-28T10:00:02.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"make\\"}","call_id":"c1"}}
        {"timestamp":"2026-09-28T10:00:03.000Z","type":"event_msg","payload":{"type":"exec_approval_request","command":["make","install"]}}
        """)
        let now = ISO8601DateFormatter().date(from: "2026-09-28T10:00:10Z")!
        var s = p.snapshot(now: now)
        XCTAssertEqual(p.originator, "Codex Desktop")
        XCTAssertEqual(s.activity, .needsInput)
        XCTAssertEqual(s.items.map(\.role), [.user, .tool])
        XCTAssertEqual(s.items.last?.text, "make")

        p.ingest(text: """
        {"timestamp":"2026-09-28T10:00:20.000Z","type":"event_msg","payload":{"type":"exec_command_begin"}}
        {"timestamp":"2026-09-28T10:00:30.000Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Shipped."}}
        {"timestamp":"2026-09-28T10:00:31.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":37.5,"window_minutes":300,"resets_in_seconds":600},"secondary":{"used_percent":12,"window_minutes":10080}}}}
        """)
        s = p.snapshot(now: now.addingTimeInterval(60))
        XCTAssertEqual(s.activity, .done)
        XCTAssertEqual(s.detail, "Shipped.")
        XCTAssertEqual(p.rateLimits?.primary?.usedPercent, 37.5)
    }
}

final class UsageAPITests: XCTestCase {
    func testOpenRouterRemaining() throws {
        let config = UsageProviderConfig(id: "or", kind: .openrouter)
        let r = try UsageAPI.parse(Data(#"{"data":{"total_credits":100,"total_usage":25.5}}"#.utf8), for: config)
        XCTAssertEqual(r.headline, "$74.50 left")
        XCTAssertEqual(r.remaining!, 0.745, accuracy: 0.001)
    }

    func testDeepSeekBalance() throws {
        let config = UsageProviderConfig(id: "ds", kind: .deepseek)
        let r = try UsageAPI.parse(Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00"}]}"#.utf8), for: config)
        XCTAssertEqual(r.headline, "¥110.00 left")
    }

    func testOpenAISpendWithBudget() throws {
        let config = UsageProviderConfig(id: "oa", kind: .openai, monthlyBudget: 100)
        let body = #"{"data":[{"results":[{"amount":{"value":12.5,"currency":"usd"}}]},{"results":[{"amount":{"value":7.5}}]}]}"#
        let r = try UsageAPI.parse(Data(body.utf8), for: config)
        XCTAssertEqual(r.headline, "$20.00 this month")
        XCTAssertEqual(r.remaining!, 0.8, accuracy: 0.001)
    }

    func testAnthropicCostReportIsInCents() throws {
        let config = UsageProviderConfig(id: "an", kind: .anthropic)
        let r = try UsageAPI.parse(Data(#"{"data":[{"results":[{"amount":"1234.5","currency":"USD"}]}]}"#.utf8), for: config)
        XCTAssertEqual(r.headline, "$12.35 this month")
    }

    func testClaudePlanWindows() throws {
        let config = UsageProviderConfig(id: "cp", kind: .claudePlan)
        let r = try UsageAPI.parse(Data(#"{"five_hour":{"utilization":42.0,"resets_at":null},"seven_day":{"utilization":80}}"#.utf8), for: config)
        XCTAssertEqual(r.headline, "5h 42%")
        XCTAssertEqual(r.remaining!, 0.2, accuracy: 0.001)
        XCTAssertEqual(r.lines.count, 2)
    }

    func testCustomDotPath() throws {
        let config = UsageProviderConfig(id: "c", kind: .custom, customJSONPath: "data.accounts.0.credit")
        let r = try UsageAPI.parse(Data(#"{"data":{"accounts":[{"credit":"9.5"}]}}"#.utf8), for: config)
        XCTAssertEqual(r.headline, "9.50")
    }

    func testRateLimitErrorsAreReadable() {
        XCTAssertEqual(UsageAPI.Failure.http(429, "{}").localizedDescription, "Rate limited by the provider")
        let body = #"{"type":"error","error":{"type":"invalid_request_error","message":"Bad key"}}"#
        XCTAssertEqual(UsageAPI.Failure.http(400, body).localizedDescription, "HTTP 400: Bad key")
    }

    func testBackoffHonorsRetryAfterThenDoubles() {
        XCTAssertEqual(UsageAPI.backoff(failures: 1, retryAfter: "120"), 120)
        XCTAssertEqual(UsageAPI.backoff(failures: 1, retryAfter: nil), 300)
        XCTAssertEqual(UsageAPI.backoff(failures: 3, retryAfter: nil), 1200)
        XCTAssertEqual(UsageAPI.backoff(failures: 9, retryAfter: nil), 3600)
        XCTAssertEqual(UsageAPI.minimumInterval(for: .claudePlan), 300)
    }

    func testBudgetInput() {
        XCTAssertEqual(UsageProviderConfig.budget(from: " $1,000 "), 1000)
        XCTAssertEqual(UsageProviderConfig.budget(from: "250.5"), 250.5)
        for bad in ["", "abc", "inf", "nan", "-5", "0", "99999999999999999999"] {
            XCTAssertNil(UsageProviderConfig.budget(from: bad), bad)
        }
    }

    func testOpenAIRequestUsesMonthStart() {
        let config = UsageProviderConfig(id: "oa", kind: .openai)
        let req = UsageAPI.request(for: config, key: "sk-admin", now: Date())
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-admin")
        XCTAssertTrue(req?.url?.absoluteString.contains("organization/costs?start_time=") ?? false)
    }
}

final class KeychainTests: XCTestCase {
    /// "No such item" is an answer, not a failure: only unreadable items throw.
    func testPresenceWithoutReadingTheSecret() throws {
        let account = "tessera-test-\(UUID().uuidString)"
        XCTAssertFalse(Keychain.contains(account: account))
        XCTAssertNil(try Keychain.read(account: account))
        Keychain.set("secret", account: account)
        defer { Keychain.set(nil, account: account) }
        XCTAssertTrue(Keychain.contains(account: account))
        XCTAssertEqual(try Keychain.read(account: account), "secret")
    }
}

final class ClaudeOAuthTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func credentials(expiresIn: TimeInterval) -> String {
        #"{"claudeAiOauth":{"accessToken":"old-at","refreshToken":"old-rt","expiresAt":\#(Int((now.timeIntervalSince1970 + expiresIn) * 1000)),"scopes":["user:inference","user:profile"],"subscriptionType":"max"},"mcpOAuth":{"k":1}}"#
    }

    func testTokenIsUsableUntilCloseToExpiry() {
        XCTAssertEqual(ClaudeOAuth.token(in: credentials(expiresIn: 3600), now: now)?.value, "old-at")
        XCTAssertNil(ClaudeOAuth.token(in: credentials(expiresIn: 120), now: now))
        XCTAssertNil(ClaudeOAuth.token(in: credentials(expiresIn: -60), now: now))
    }
}

final class TerminalSnapshotTests: XCTestCase {
    func testSnapshotRoundTripsScreenAndColors() {
        let source = TerminalMirror(cols: 40, rows: 6)
        source.feed(Array("plain line\r\n\u{1b}[31mred\u{1b}[0m and \u{1b}[1;38;2;1;2;3mtrue\u{1b}[0m\r\n$ ".utf8))
        let bytes = TerminalSnapshotEncoder.encode(source.terminal)
        let copy = TerminalMirror(cols: 40, rows: 6)
        copy.reset(cols: 40, rows: 6, bytes: bytes)
        XCTAssertEqual(copy.terminal.screenTail(6), source.terminal.screenTail(6))
        XCTAssertEqual(copy.terminal.getCursorLocation().x, source.terminal.getCursorLocation().x)
        XCTAssertEqual(copy.terminal.getCursorLocation().y, source.terminal.getCursorLocation().y)
        let red = copy.terminal.getCharData(col: 0, row: 1)!.attribute.fg
        XCTAssertEqual(red, .ansi256(code: 1))
    }

    func testMirrorRedrawsOnItsOwnRevision() {
        let mirror = TerminalMirror(cols: 20, rows: 4)
        let redraw = expectation(description: "revision observed")
        withObservationTracking { _ = mirror.revision } onChange: { redraw.fulfill() }
        mirror.feed(Array("hi".utf8))
        wait(for: [redraw], timeout: 1)
    }

    func testSmartPunctuationIsUndone() {
        XCTAssertEqual(RemoteSession.undoSmartPunctuation("echo “hi” — it’s…"), "echo \"hi\" -- it's...")
    }

    func testTranscriptLinesDropsBlankEdges() {
        let m = TerminalMirror(cols: 20, rows: 6)
        m.feed(Array("\r\n\r\nhello\r\nworld\r\n".utf8))
        XCTAssertEqual(m.terminal.transcriptLines(), ["hello", "world"])
    }

    func testScreenTailFollowsContentNotBottomRows() {
        let m = TerminalMirror(cols: 40, rows: 30)
        m.feed(Array("tick 1\r\ntick 2\r\nDo you want to proceed? (y/n) ".utf8))
        XCTAssertEqual(m.terminal.liveEdgeRow, 2)
        let tail = m.terminal.screenTail(14)
        XCTAssertEqual(tail, ["tick 1", "tick 2", "Do you want to proceed? (y/n)"])
        XCTAssertNotNil(TerminalActivityTracker.promptLine(in: tail))
    }

    func testPairingCodeNormalization() {
        let code = SecureChannel.makePairingCode()
        XCTAssertEqual(SecureChannel.normalize(code).count, 20)
        XCTAssertEqual(SecureChannel.normalize("ab-cd ef"), "ABCDEF")
    }

    func testWireRoundTrip() throws {
        let msg = HostMessage.tile(TileInfo(id: "t1", kind: .terminal, flavor: .claude, title: "claude", activity: .needsInput, attention: true))
        let back = try WireProtocol.decode(HostMessage.self, from: WireProtocol.encode(msg))
        guard case .tile(let info) = back else { return XCTFail("wrong case") }
        XCTAssertEqual(info.activity, .needsInput)
        XCTAssertEqual(info.flavor, .claude)
    }
}

final class WireCompatibilityTests: XCTestCase {
    /// A newer Mac may send flavors and states this build doesn't know; the tile list still arrives.
    func testUnknownFlavorsAndStatesReadAsGeneric() throws {
        let json = #"{"tiles":{"_0":[{"id":"t","kind":"terminal","flavor":"hologram","title":"x","subtitle":"","#
            + #""activity":"dreaming","attention":false,"lastActivityAt":0}]}}"#
        guard case .tiles(let tiles) = try WireProtocol.decode(HostMessage.self, from: Data(json.utf8)) else { return XCTFail("wrong case") }
        XCTAssertEqual(tiles.map(\.flavor), [.custom])
        XCTAssertEqual(tiles.map(\.activity), [.idle])
        XCTAssertEqual(try JSONDecoder().decode([AgentFlavor].self, from: Data(#"["dsh","codex"]"#.utf8)), [.dsh, .codex])
    }
}

final class TileGroupsTests: XCTestCase {
    func testTileLivesInOneTabAndDeletingKeepsTiles() {
        var g = TileGroups()
        let a = g.create(named: "  Backend ")
        let b = g.create(named: "")
        XCTAssertEqual(g.list.map(\.name), ["Backend", "Tab 2"])
        g.assign("t1", to: a)
        g.assign("t1", to: b)
        XCTAssertEqual(g.group(of: "t1")?.id, b)
        XCTAssertTrue(g.members(of: a).isEmpty)
        g.rename(b, to: "Research")
        g.rename(b, to: "   ")
        XCTAssertEqual(g.group(of: "t1")?.name, "Research")
        g.assign("t1", to: nil)
        XCTAssertNil(g.group(of: "t1"))
        g.assign("t2", to: a)
        g.delete(a)
        XCTAssertNil(g.group(of: "t2"))
        XCTAssertEqual(g.list.count, 1)
    }

    func testGroupsRoundTripThroughJSON() throws {
        var g = TileGroups()
        let a = g.create(named: "Web")
        g.assign("w1", to: a)
        let back = try JSONDecoder().decode(TileGroups.self, from: JSONEncoder().encode(g))
        XCTAssertEqual(back, g)
    }
}

final class RemoteVitalsTests: XCTestCase {
    func testQuantizedReadingsDifferOnlyWhenTheChipWould() {
        var a = MachineVitals(id: "m", name: "m", isLocal: true)
        a.cpu = 0.4213
        a.memory = 0.6671
        a.temperature = 58.3
        a.gpuPowerW = 41.8
        a.load = 0.52
        var b = a
        b.cpu = 0.4189
        b.temperature = 57.8
        b.gpuPowerW = 42.3
        b.load = 0.47
        a.quantize()
        b.quantize()
        XCTAssertEqual(a, b)
        b.cpu = 0.436
        b.quantize()
        XCTAssertNotEqual(a, b)
    }

    let sample = """
    @stat cpu  13388591 4655 4582035 301064634 1058763 0 17213 0 0 0
    @memtotal 127600812
    @memavail 65669088
    @load 1.15
    @ncpu 20
    @ctemp 59200
    @gpu NVIDIA GB10, 3, 53, 14.93
    """

    func testParsesSparkProbe() {
        let r = RemoteVitals.parse(sample)
        XCTAssertEqual(r.cores, 20)
        XCTAssertEqual(r.gpuName, "NVIDIA GB10")
        XCTAssertEqual(r.gpu!, 0.03, accuracy: 0.0001)
        XCTAssertEqual(r.cpuTemperature!, 59.2, accuracy: 0.01)
        XCTAssertEqual(r.temperature!, 53, accuracy: 0.01)  // GPU temperature, like nvidia-smi
        XCTAssertEqual(r.memory!, 1 - 65669088.0 / 127600812.0, accuracy: 0.0001)
        XCTAssertEqual(r.memoryTotalGB!, 121.7, accuracy: 0.1)
    }

    func testHostileOutputCantOverflow() {
        let r = RemoteVitals.parse("""
        @stat cpu 18446744073709551615 18446744073709551615 1 18446744073709551615 9
        @memtotal 1e30
        @memavail 5
        @ctemp inf
        @gpu x, 1e30, nan, 99999999999999999999
        """)
        XCTAssertNotNil(r.cpuSample)
        XCTAssertNil(r.memory)
        XCTAssertNil(r.cpuTemperature)
        XCTAssertNil(r.gpu)
        XCTAssertNil(r.gpuTemperature)
        XCTAssertNil(r.gpuPowerW)
        // Memory stays a fraction however the two numbers relate.
        XCTAssertEqual(RemoteVitals.parse("@memtotal 1e-300\n@memavail 1e11").memory, 0)
    }

    func testCPUUtilizationFromDeltas() {
        let a = RemoteVitals.parse("@stat cpu 100 0 100 800 0 0 0 0").cpuSample
        let b = RemoteVitals.parse("@stat cpu 150 0 150 900 0 0 0 0").cpuSample
        XCTAssertNil(a?.utilization(since: nil))
        XCTAssertEqual(b!.utilization(since: a)!, 0.5, accuracy: 0.0001)
    }

    func testHostsFromSSHConfigAndValidation() {
        let config = """
        Host *
          ServerAliveInterval 30
        Host gpu-box-1 gpu-box-2
          HostName 100.101.102.103
        Host=gpu-box-3
        Host github.com !bad dev-*
        """
        XCTAssertEqual(RemoteVitals.configuredHosts(in: config), ["gpu-box-1", "gpu-box-2", "gpu-box-3", "github.com"])
        XCTAssertFalse(MachineConfig.isValidHost("-oProxyCommand=evil"))
        XCTAssertFalse(MachineConfig.isValidHost("host; rm -rf /"))
        XCTAssertTrue(MachineConfig.isValidHost("me@10.0.0.4"))
    }
}

final class SessionResumeTests: XCTestCase {
    let fixedId = "11111111-2222-3333-4444-555555555555"

    func testClaudeGetsAssignedIdAndResumesIt() {
        let (run, id) = SessionResume.prepareLaunch("claude --model opus", newId: { self.fixedId })
        XCTAssertEqual(run, "claude --model opus --session-id \(fixedId)")
        XCTAssertEqual(id, fixedId)
        XCTAssertEqual(SessionResume.resumeCommand(original: "claude --model opus", sessionId: fixedId),
                       "claude --model opus --resume \(fixedId)")
        XCTAssertEqual(SessionResume.resumeCommand(original: "claude -c", sessionId: nil), "claude --continue")
    }

    func testCommandsThatAlreadyPickASessionAreLeftAlone() {
        XCTAssertEqual(SessionResume.prepareLaunch("claude --continue").command, "claude --continue")
        XCTAssertNil(SessionResume.prepareLaunch("claude -p hi").sessionId)
        XCTAssertEqual(SessionResume.prepareLaunch("claude --resume abc-1").sessionId, "abc-1")
        XCTAssertNil(SessionResume.sessionId(in: "claude --resume abc --fork-session"))
        XCTAssertEqual(SessionResume.prepareLaunch("npm test").command, "npm test")
    }

    func testCodexResumeKeepsFlagsAndSkipsNonSessionSubcommands() {
        XCTAssertEqual(SessionResume.resumeCommand(original: "codex -m gpt-6", sessionId: "01a0-x"), "codex resume 01a0-x -m gpt-6")
        XCTAssertEqual(SessionResume.resumeCommand(original: "codex resume old --last", sessionId: nil), "codex resume --last")
        XCTAssertEqual(SessionResume.sessionId(in: "codex resume 01a0-x"), "01a0-x")
        XCTAssertNil(SessionResume.resumeCommand(original: "codex exec 'do it'", sessionId: "x"))
    }

    func testOtherToolsAndUnsafeIds() {
        XCTAssertEqual(SessionResume.resumeCommand(original: "opencode", sessionId: "ses_1"), "opencode -s ses_1")
        XCTAssertEqual(SessionResume.resumeCommand(original: "omp", sessionId: nil), "omp -c")
        XCTAssertNil(SessionResume.resumeCommand(original: "gemini", sessionId: nil))
        XCTAssertEqual(SessionResume.resumeCommand(original: "claude", sessionId: "x; rm -rf ~"), "claude --continue")
    }

    func testLaunchersResumeThroughThemselves() {
        XCTAssertEqual(SessionResume.tool(for: "codex-work"), .codex)
        XCTAssertEqual(SessionResume.resumeCommand(original: "codex-work", sessionId: "01a0-x"), "codex-work resume 01a0-x")
        XCTAssertEqual(SessionResume.resumeCommand(original: "/Users/me/.local/bin/claude_work --model opus", sessionId: fixedId),
                       "/Users/me/.local/bin/claude_work --model opus --resume \(fixedId)")
        XCTAssertNil(SessionResume.tool(for: "codexify"))
        XCTAssertNil(SessionResume.tool(for: "ls -la"))
    }

    func testShellEventParsing() {
        let n = "abc123"
        let b64 = Data("codex-work --yolo".utf8).base64EncodedString()
        XCTAssertEqual(ShellEvent.parse("cmd;\(n);\(b64)", nonce: n), .command(typed: "codex-work --yolo", expanded: nil))
        let cx = Data("cx".utf8).base64EncodedString()
        XCTAssertEqual(ShellEvent.parse("cmd;\(n);\(cx);\(b64)", nonce: n), .command(typed: "cx", expanded: "codex-work --yolo"))
        XCTAssertEqual(ShellEvent.parse("done;\(n);130", nonce: n), .prompt(status: 130))
        XCTAssertEqual(ShellEvent.parse("fresh;\(n)", nonce: n), .startedFresh)
        XCTAssertNil(ShellEvent.parse("cmd;\(n);not base64!", nonce: n))
        XCTAssertNil(ShellEvent.parse("hello", nonce: n))
    }

    func testMissingProgramReport() {
        XCTAssertEqual(ShellEvent.parse("missing;abc", nonce: "abc"), .programMissing)
        XCTAssertNil(ShellEvent.parse("missing;forged", nonce: "abc"))
    }

    /// Output printed into a tile (a cat'ed file, an ssh session) can't plant a command to resume.
    func testForgedReportsAreIgnored() {
        let b64 = Data("claude-evil".utf8).base64EncodedString()
        XCTAssertNil(ShellEvent.parse("cmd;guess;\(b64)", nonce: "real-secret"))
        XCTAssertNil(ShellEvent.parse("cmd;;\(b64)", nonce: ""))
        XCTAssertNil(ShellEvent.parse("cmd;\(b64)", nonce: "real-secret"))
    }

    func testPrefixesAreKeptAndCompoundLinesRefused() {
        XCTAssertEqual(SessionResume.tool(for: "FOO=1 env BAR=2 claude --model opus"), .claude)
        XCTAssertEqual(SessionResume.resumeCommand(original: "FOO=1 codex-work", sessionId: "abc"), "FOO=1 codex-work resume abc")
        XCTAssertNil(SessionResume.tool(for: "cd work && claude"))
        XCTAssertNil(SessionResume.tool(for: "claude | tee log"))
        XCTAssertNil(SessionResume.tool(for: "echo $(claude)"))
    }

    func testIdsAreOnlyInjectedIntoTheToolItself() {
        XCTAssertNil(SessionResume.prepareLaunch("claude-work").sessionId)
        XCTAssertNotNil(SessionResume.prepareLaunch("/opt/bin/claude").sessionId)
        XCTAssertEqual(SessionResume.freshLaunch(original: "claude-work --resume abc", sessionId: fixedId), "claude-work")
        XCTAssertEqual(SessionResume.freshLaunch(original: "codex-work resume abc --yolo"), "codex-work --yolo")
    }

    func testLaunchScriptFallsBackOnlyOnQuickFailure() {
        let posix = LaunchScript.build(primary: "claude --resume x", fallback: "claude", followUp: "exec zsh -l -i", dialect: .posix, nonce: "n")
        XCTAssertTrue(posix.hasPrefix("__t=$SECONDS; claude --resume x; __s=$?;"))
        // Not found (126/127) is reported; other quick failures, below the signal range, start fresh.
        XCTAssertTrue(posix.contains("if [ $__s -eq 126 ] || [ $__s -eq 127 ]; then printf '\\033]6973;missing;n\\007'; elif"))
        XCTAssertTrue(posix.contains("[ $__s -lt 126 ]") && posix.contains(";fresh;n") && posix.contains("; claude; fi;"))
        XCTAssertTrue(posix.hasSuffix("fi; exec zsh -l -i"))
        let plain = LaunchScript.build(primary: "npm test", fallback: nil, followUp: "exec zsh -l -i", dialect: .posix, nonce: "n")
        XCTAssertTrue(plain.contains(";missing;n") && !plain.contains("fresh") && plain.hasSuffix("fi; exec zsh -l -i"))
        let fish = LaunchScript.build(primary: "codex resume x", fallback: "codex", followUp: "exec fish -l -i", dialect: .fish, nonce: "n")
        XCTAssertTrue(fish.contains("set -l __s $status") && fish.contains(";missing;n") && fish.contains("else if test $__s -ne 0 -a $__s -lt 126"))
        XCTAssertTrue(fish.hasSuffix("end; exec fish -l -i"))
    }

    func testFreshLaunchReclaimsUnsavedId() {
        XCTAssertEqual(SessionResume.freshLaunch(original: "claude --model opus --resume x", sessionId: fixedId),
                       "claude --model opus --session-id \(fixedId)")
        XCTAssertEqual(SessionResume.freshLaunch(original: "codex resume abc", sessionId: fixedId), "codex")
    }

    /// Scripts run in shells that speak them; everything else (tcsh, nu, …) runs them under zsh, and
    /// tiles start each shell with flags it accepts.
    func testShellsGetScriptsAndFlagsTheyUnderstand() {
        XCTAssertEqual(LaunchScript.dialect(forShell: "/bin/zsh"), .posix)
        XCTAssertEqual(LaunchScript.dialect(forShell: "/opt/homebrew/bin/bash"), .posix)
        XCTAssertEqual(LaunchScript.dialect(forShell: "/opt/homebrew/bin/fish"), .fish)
        XCTAssertNil(LaunchScript.dialect(forShell: "/bin/tcsh"))
        XCTAssertNil(LaunchScript.dialect(forShell: "/opt/homebrew/bin/nu"))
        XCTAssertEqual(LoginShell.scriptShell(for: "/bin/tcsh"), "/bin/zsh")
        XCTAssertEqual(LoginShell.scriptShell(for: "/bin/bash"), "/bin/bash")
        XCTAssertEqual(ShellIntegration.interactiveArguments("/bin/bash", nonce: "n"), ["-l", "-i"])
        XCTAssertEqual(ShellIntegration.interactiveArguments("/bin/tcsh", nonce: "n"), ["-l"])
        XCTAssertEqual(ShellIntegration.interactiveArguments("/opt/homebrew/bin/nu", nonce: "n"), [])
        XCTAssertEqual(LoginShell.tagged("found", in: "hello\n@found claude\n@foundx no\n@found codex"), ["claude", "codex"])
    }

    func testShellWordsRoundTrip() {
        let words = ShellWords.split(#"claude --append-system-prompt "be brief, it's fine" -x 'a b'"#)
        XCTAssertEqual(words, ["claude", "--append-system-prompt", "be brief, it's fine", "-x", "a b"])
        XCTAssertEqual(ShellWords.split(ShellWords.join(words)), words)
    }
}

final class WebAddressTests: XCTestCase {
    func testLocalAndPrivateHostsGetHTTP() {
        XCTAssertEqual(WebAddress.normalize("127.0.0.1:3080/?token=abc")?.absoluteString, "http://127.0.0.1:3080/?token=abc")
        XCTAssertEqual(WebAddress.normalize("localhost:3000")?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(WebAddress.normalize("100.101.102.103:8080")?.absoluteString, "http://100.101.102.103:8080")
        XCTAssertEqual(WebAddress.normalize("[::1]:5173/app")?.absoluteString, "http://[::1]:5173/app")
        XCTAssertEqual(WebAddress.normalize("myhost.local")?.absoluteString, "http://myhost.local")
    }

    func testPublicHostsGetHTTPSAndSchemesAreKept() {
        XCTAssertEqual(WebAddress.normalize("github.com/enntity")?.absoluteString, "https://github.com/enntity")
        XCTAssertEqual(WebAddress.normalize("http://example.com")?.absoluteString, "http://example.com")
        XCTAssertEqual(WebAddress.normalize("8.8.8.8")?.absoluteString, "https://8.8.8.8")
    }

    func testSearchesStaySearches() {
        XCTAssertTrue(WebAddress.normalize("swift concurrency")!.absoluteString.hasPrefix("https://www.google.com/search?q=swift"))
        XCTAssertFalse(WebAddress.looksLikeAddress("hello"))
        XCTAssertTrue(WebAddress.looksLikeAddress("localhost:3000"))
        XCTAssertFalse(WebAddress.looksLikeAddress(".hidden"))
    }
}

final class RestorePlanTests: XCTestCase {
    func testDuplicateSessionIdsStartFresh() {
        let plan = RestorePlan.plan([
            .init(id: "a", command: "codex-work", cwd: "/w", sessionId: "S1"),
            .init(id: "b", command: "codex-work resume S1", cwd: "/w", sessionId: nil),
            .init(id: "c", command: "claude", cwd: "/w", sessionId: "S1")
        ])
        XCTAssertEqual(plan["a"]?.sessionId, "S1")
        XCTAssertNil(plan["b"]?.sessionId)
        XCTAssertNil(plan["c"]?.sessionId)
        XCTAssertEqual(plan["b"]?.mayContinueLatest, false)
    }

    /// The bug seen in the wild: an unbound `resume --last` next to a bound tile in the same folder.
    func testBindableToolsNeverContinueLatest() {
        let plan = RestorePlan.plan([
            .init(id: "bound", command: "codex-work", cwd: "/w", sessionId: "S1"),
            .init(id: "unbound", command: "codex-work resume --last", cwd: "/w", sessionId: nil),
            .init(id: "solo", command: "claude", cwd: "/other", sessionId: nil)
        ])
        XCTAssertEqual(plan["unbound"], .init(sessionId: nil, mayContinueLatest: false))
        XCTAssertEqual(plan["solo"], .init(sessionId: nil, mayContinueLatest: false))
    }

    func testOtherToolsContinueOnlyWhenAloneInTheFolder() {
        let plan = RestorePlan.plan([
            .init(id: "g1", command: "grok-work", cwd: "/w", sessionId: nil),
            .init(id: "o1", command: "opencode", cwd: "/w", sessionId: nil),
            .init(id: "o2", command: "opencode -m x", cwd: "/w", sessionId: nil)
        ])
        XCTAssertEqual(plan["g1"]?.mayContinueLatest, true)
        XCTAssertEqual(plan["o1"]?.mayContinueLatest, false)
        XCTAssertEqual(plan["o2"]?.mayContinueLatest, false)
    }

    func testContinuesLatestDetection() {
        XCTAssertTrue(SessionResume.continuesLatest("codex-work resume --last"))
        XCTAssertTrue(SessionResume.continuesLatest("FOO=1 claude --continue"))
        XCTAssertFalse(SessionResume.continuesLatest("codex resume abc"))
        XCTAssertFalse(SessionResume.continuesLatest("claude"))
    }
}

final class AgentAppTests: XCTestCase {
    func testNewConversationLinks() {
        XCTAssertEqual(AgentApp.claude.newConversationURL(folder: "/Users/me/my proj", prompt: "fix the build")?.absoluteString,
                       "claude://code/new?folder=/Users/me/my%20proj&q=fix%20the%20build")
        XCTAssertEqual(AgentApp.codex.newConversationURL(folder: "/w", prompt: nil)?.absoluteString, "codex://threads/new?path=/w")
        XCTAssertEqual(AgentApp.codex.newConversationURL(folder: nil, prompt: "  ")?.absoluteString, "codex://threads/new")
        // Characters meaningful in a query stay inside their parameter.
        let url = AgentApp.claude.newConversationURL(folder: nil, prompt: "a&b=c?d#e C++")!
        XCTAssertEqual(url.absoluteString, "claude://code/new?q=a%26b%3Dc%3Fd%23e%20C%2B%2B")
    }

    func testConversationLinksAndNames() {
        XCTAssertEqual(AgentApp.claude.conversationURL("local_1")?.absoluteString, "claude://code/continue?session=local_1")
        XCTAssertEqual(AgentApp.codex.conversationURL("abc-1")?.absoluteString, "codex://threads/abc-1")
        XCTAssertEqual(AgentApp.allCases.map(\.name), ["Claude app", "Codex app"])
    }

    func testOnlyInstalledAppsTakeTheirConversations() {
        XCTAssertEqual(AgentApp(flavor: .claudeDesktop), .claude)
        XCTAssertEqual(AgentApp(flavor: .codexDesktop), .codex)
        // The CLIs and dsh are tiles on the board, not app conversations.
        XCTAssertNil(AgentApp(flavor: .claude))
        XCTAssertNil(AgentApp(flavor: .dsh))
        XCTAssertEqual(AgentApp.opening(.codexDesktop, installed: [.claude, .codex]), .codex)
        XCTAssertNil(AgentApp.opening(.codexDesktop, installed: [.claude]))
        XCTAssertNil(AgentApp.opening(.shell, installed: AgentApp.allCases))
        // Paging between open tiles and Show Transcript stay in Tessera.
        XCTAssertNil(AgentApp.opening(.claudeDesktop, installed: [.claude], inApp: false))
    }
}
