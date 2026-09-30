import XCTest
@testable import TesseraHost
@testable import TesseraKit

/// Binding decides which conversation a terminal tile resumes; a wrong match would resume someone
/// else's. These write fake Codex rollouts and Claude transcripts into a temporary folder.
final class SessionBindingTests: XCTestCase {
    let t0 = Date().addingTimeInterval(-120)

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-bind-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func candidate(_ id: String, _ cwd: String, at offset: TimeInterval, continuing: Bool = false) -> SessionBinding.Candidate {
        SessionBinding.Candidate(tileId: id, cwd: cwd, launchedAt: t0.addingTimeInterval(offset), continuing: continuing)
    }

    private func write(_ text: String, to url: URL, created: Date? = nil, modified: Date? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        var attrs: [FileAttributeKey: Any] = [:]
        if let created { attrs[.creationDate] = created }
        if let modified { attrs[.modificationDate] = modified }
        if !attrs.isEmpty { try FileManager.default.setAttributes(attrs, ofItemAtPath: url.path) }
    }

    func testCodexRolloutsMatchEarliestFittingThread() throws {
        let root = try tempDir()
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let day = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
        func rollout(_ id: String, cwd: String = "/w", startedAt offset: TimeInterval, originator: String = "codex_cli_rs",
                     extra: String = "", modified: Date? = nil) throws {
            let started = ISO8601DateFormatter().string(from: t0.addingTimeInterval(offset))
            try write(#"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)","originator":"\#(originator)","timestamp":"\#(started)"\#(extra)}}"# + "\n",
                      to: day.appendingPathComponent("rollout-\(id).jsonl"), modified: modified)
        }
        try rollout("r0", startedAt: -60, modified: t0.addingTimeInterval(-60))
        try rollout("r1", startedAt: 5)
        try rollout("r2", startedAt: 30)
        try rollout("desk", startedAt: 1, originator: "Codex Desktop")
        try rollout("sub", startedAt: 2, extra: #","thread_source":"review""#)
        try rollout("r3", cwd: "/x", startedAt: 1)

        XCTAssertEqual(CodexRollouts.bind([candidate("a", "/w/.", at: 0)], claimed: [], root: root), ["a": "r1"])
        XCTAssertEqual(CodexRollouts.bind([candidate("a", "/w", at: 0)], claimed: ["r1"], root: root), ["a": "r2"])
        // The earlier launch picks first; each thread goes to one tile.
        XCTAssertEqual(CodexRollouts.bind([candidate("b", "/w", at: 20), candidate("a", "/w", at: 0)], claimed: [], root: root),
                       ["a": "r1", "b": "r2"])
        // Nothing started after this launch; a continue matches what was written since instead.
        XCTAssertEqual(CodexRollouts.bind([candidate("c", "/w", at: 100)], claimed: [], root: root), [:])
        XCTAssertEqual(CodexRollouts.bind([candidate("c", "/w", at: 100, continuing: true)], claimed: [], root: root), ["c": "r1"])
    }

    func testClaudeTranscriptsMatchEarliestFittingConversation() throws {
        let projects = try tempDir()
        let folder = "/w/app"
        func transcript(_ id: String, cwd: String = folder, created offset: TimeInterval, desktop: Bool = false, modified: Date? = nil) throws {
            let entry = desktop ? #","entrypoint":"claude-desktop""# : ""
            try write(#"{"type":"user","cwd":"\#(cwd)"\#(entry)}"# + "\n",
                      to: projects.appendingPathComponent(ClaudeSessions.projectFolder(for: cwd)).appendingPathComponent("\(id).jsonl"),
                      created: t0.addingTimeInterval(offset), modified: modified ?? t0.addingTimeInterval(offset))
        }
        try transcript("c0", created: -60)
        try transcript("c1", created: 5, modified: Date())
        try transcript("c2", created: 30)
        try transcript("desk", created: 1, desktop: true)

        XCTAssertEqual(ClaudeSessions.bind([candidate("a", folder, at: 0)], claimed: [], projects: projects), ["a": "c1"])
        XCTAssertEqual(ClaudeSessions.bind([candidate("a", folder, at: 0)], claimed: ["c1"], projects: projects), ["a": "c2"])
        XCTAssertEqual(ClaudeSessions.bind([candidate("c", folder, at: 100)], claimed: [], projects: projects), [:])
        XCTAssertEqual(ClaudeSessions.bind([candidate("c", folder, at: 100, continuing: true)], claimed: [], projects: projects), ["c": "c1"])
    }

    func testSameFolderLaunchesWithinAMinuteStayUnbound() {
        let kept = SessionBinding.unambiguous([candidate("a", "/w", at: 0), candidate("b", "/w", at: 30),
                                               candidate("c", "/x", at: 10), candidate("d", "/w", at: 100)])
        XCTAssertEqual(kept.map(\.tileId), ["c", "d"])
    }
}
