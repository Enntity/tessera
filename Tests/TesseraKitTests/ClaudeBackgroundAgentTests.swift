import XCTest
@testable import TesseraKit

/// A Claude session whose turn has ended but whose background subagents are still running is working,
/// the way the Claude app's sidebar dot shows it.
final class ClaudeBackgroundAgentTests: XCTestCase {
    private let t0 = ISO8601DateFormatter().date(from: "2026-09-28T10:00:00Z")!

    private func launched(_ agentId: String, _ description: String, toolId: String) -> String {
        """
        {"type":"assistant","uuid":"a-\(toolId)","timestamp":"2026-09-28T10:00:05.000Z","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"\(toolId)","name":"Agent","input":{"description":"\(description)","run_in_background":true}}]}}
        {"type":"user","uuid":"r-\(toolId)","timestamp":"2026-09-28T10:00:06.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\(toolId)","content":"Async agent launched successfully."}]},"toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"\(agentId)","description":"\(description)"}}
        """
    }

    private func notified(_ agentId: String, status: String, at ts: String) -> String {
        let text = "<task-notification>\\n<task-id>\(agentId)</task-id>\\n<status>\(status)</status>\\n<summary>Agent finished</summary>\\n</task-notification>"
        return """
        {"type":"user","uuid":"n-\(agentId)","timestamp":"\(ts)","message":{"role":"user","content":"\(text)"}}
        {"type":"assistant","uuid":"e-\(agentId)","timestamp":"\(ts)","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Noted."}]}}
        """
    }

    private func parser() -> ClaudeTranscriptParser {
        var p = ClaudeTranscriptParser()
        p.ingest(text: """
        {"type":"user","uuid":"u1","timestamp":"2026-09-28T10:00:00.000Z","message":{"role":"user","content":"Split the files"}}
        \(launched("agentA", "Split group A", toolId: "t1"))
        \(launched("agentB", "Split group B", toolId: "t2"))
        {"type":"assistant","uuid":"a3","timestamp":"2026-09-28T10:00:10.000Z","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Waiting on both groups."}]}}
        """)
        return p
    }

    func testTurnEndedWithRunningSubagentsIsWorking() {
        let s = parser().snapshot(now: t0.addingTimeInterval(120))
        XCTAssertEqual(s.activity, .working)
        XCTAssertEqual(s.detail, "Waiting on 2 subagents")
    }

    func testFinishedSubagentsReleaseTheSession() {
        var p = parser()
        p.ingest(text: notified("agentA", status: "completed", at: "2026-09-28T10:05:00.000Z"))
        var s = p.snapshot(now: t0.addingTimeInterval(400))
        XCTAssertEqual(s.activity, .working)
        XCTAssertEqual(s.detail, "Waiting on Split group B")

        p.ingest(text: notified("agentB", status: "failed", at: "2026-09-28T10:06:00.000Z"))
        s = p.snapshot(now: t0.addingTimeInterval(400))
        XCTAssertEqual(s.activity, .done)
    }

    func testQuietSubagentsFromADeadSessionGoIdle() {
        let p = parser()
        // Nothing written by the session or its subagents for longer than any tool call runs.
        let later = t0.addingTimeInterval(ClaudeTranscriptParser.abandonedAfter + 60)
        XCTAssertNotEqual(p.snapshot(now: later).activity, .working)
        // …unless a subagent's own transcript is still being written.
        XCTAssertEqual(p.snapshot(now: later, subagentActivity: later.addingTimeInterval(-30)).activity, .working)
    }

    func testSubagentWritingAfterTheSessionIsWorkingEvenIfItsLaunchWasntRead() {
        var p = ClaudeTranscriptParser()
        p.ingest(text: """
        {"type":"assistant","uuid":"a1","timestamp":"2026-09-28T10:00:10.000Z","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Waiting."}]}}
        """)
        let now = t0.addingTimeInterval(600)
        XCTAssertEqual(p.snapshot(now: now, subagentActivity: now.addingTimeInterval(-5)).activity, .working)
        XCTAssertEqual(p.snapshot(now: now, subagentActivity: now.addingTimeInterval(-300)).activity, .done)
        XCTAssertEqual(p.snapshot(now: now, subagentActivity: t0).activity, .done)
    }
}
