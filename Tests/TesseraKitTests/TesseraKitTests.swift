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

    func testWaitStatusDecoding() {
        XCTAssertEqual(TerminalSession.exitCode(fromWaitStatus: 256), 1)
        XCTAssertEqual(TerminalSession.exitCode(fromWaitStatus: 0), 0)
        XCTAssertEqual(TerminalSession.exitCode(fromWaitStatus: 9), 137)
    }

    func testFailedExitRaisesAttention() {
        var t = TerminalActivityTracker()
        t.noteExit(code: 2)
        XCTAssertEqual(t.activity, .failed)
        XCTAssertTrue(t.attention)
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

    func testOpenAIRequestUsesMonthStart() {
        let config = UsageProviderConfig(id: "oa", kind: .openai)
        let req = UsageAPI.request(for: config, key: "sk-admin", now: Date())
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-admin")
        XCTAssertTrue(req?.url?.absoluteString.contains("organization/costs?start_time=") ?? false)
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
        let tail = m.terminal.screenTail(14)
        XCTAssertEqual(tail.last, "Do you want to proceed? (y/n)")
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
        XCTAssertEqual(r.temperature!, 59.2, accuracy: 0.01)
        XCTAssertEqual(r.memory!, 1 - 65669088.0 / 127600812.0, accuracy: 0.0001)
        XCTAssertEqual(r.memoryTotalGB!, 121.7, accuracy: 0.1)
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
