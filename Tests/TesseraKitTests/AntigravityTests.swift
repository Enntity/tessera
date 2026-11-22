import XCTest
@testable import TesseraHost
@testable import TesseraKit

/// Antigravity's `agy` CLI: conversation detection, session ids, presence-lock binding and the
/// app's protobuf index — from the captured real screens in notes/antigravity-tessera-design.md.
final class AntigravityTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: SessionResume

    func testAgyConversationDetection() {
        for command in ["agy", "agy -c", "agy --continue", "agy -i", "agy --model m --conversation id-1",
                        "agy-work", "agy_work", "/Users/me/.local/bin/agy"] {
            XCTAssertEqual(SessionResume.conversationTool(for: command), .agy, command)
        }
        for command in ["agy mcp list", "agy mcp add x y", "agy models", "agy -p hi", "agy --print hi",
                        "agy --prompt hi", "agy help"] {
            XCTAssertNil(SessionResume.conversationTool(for: command), command)
        }
    }

    func testAgySessionId() {
        XCTAssertEqual(SessionResume.sessionId(in: "agy --conversation 9464b4f1-4c0a"), "9464b4f1-4c0a")
        XCTAssertEqual(SessionResume.sessionId(in: "agy --conversation=9464b4f1-4c0a"), "9464b4f1-4c0a")
        XCTAssertNil(SessionResume.sessionId(in: "agy -c"))
        XCTAssertNil(SessionResume.sessionId(in: "agy --conversation"))
        XCTAssertNil(SessionResume.sessionId(in: "agy --conversation not;rm"))
    }

    func testAgyResumeCommand() {
        XCTAssertEqual(SessionResume.resumeCommand(original: "agy", sessionId: "id-1"), "agy --conversation id-1")
        XCTAssertEqual(SessionResume.resumeCommand(original: "agy --model m", sessionId: "id-1"),
                       "agy --model m --conversation id-1")
        // Unknown id: continue the newest conversation.
        XCTAssertEqual(SessionResume.resumeCommand(original: "agy --model m", sessionId: nil), "agy --model m -c")
        // A resumed conversation must not send its interactive prompt again.
        XCTAssertEqual(SessionResume.resumeCommand(original: "agy -i 'say hi'", sessionId: "id-1"), "agy --conversation id-1")
        XCTAssertEqual(SessionResume.resumeCommand(original: "agy --prompt-interactive 'say hi' --conversation old", sessionId: "new"),
                       "agy --conversation new")
        XCTAssertEqual(SessionResume.freshLaunch(original: "agy -c --conversation old"), "agy")
        XCTAssertNil(SessionResume.resumeCommand(original: "agy mcp list", sessionId: "id-1"))
    }

    func testAgyContinuesLatest() {
        XCTAssertTrue(SessionResume.continuesLatest("agy -c"))
        XCTAssertTrue(SessionResume.continuesLatest("agy --continue"))
        XCTAssertFalse(SessionResume.continuesLatest("agy --conversation abc"))
        XCTAssertFalse(SessionResume.continuesLatest("agy"))
    }

    // MARK: Presence-lock binding

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-agy-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func lock(_ id: String, in dir: URL, modified: Date = Date()) throws -> URL {
        let url = dir.appendingPathComponent(id + ".lock")
        try Data().write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    func testSessionFromOpenLockFds() throws {
        let dir = try tempDir()
        // A pid in the group holds the lock's fd open; its name is the conversation.
        let held = try lock("9464b4f1-4c0a-4bac-b841-e36b86a424a4", in: dir)
        _ = try lock("not an id", in: dir)
        AntigravitySessions.groupPids = { _ in [11, 22] }
        defer { AntigravitySessions.groupPids = AntigravitySessions.procGroupPids }
        AntigravitySessions.vnodePaths = { pid in pid == 22 ? [held.path] : [] }
        defer { AntigravitySessions.vnodePaths = AntigravitySessions.procVnodePaths }
        XCTAssertEqual(AntigravitySessions.session(forProcessGroup: 5, presence: dir),
                       "9464b4f1-4c0a-4bac-b841-e36b86a424a4")
    }

    func testNewestLockWinsAcrossGroupPids() throws {
        let dir = try tempDir()
        // /resume moved the REPL: an older lock lingers on another fd.
        let old = try lock("old-conv", in: dir, modified: Date().addingTimeInterval(-600))
        let new = try lock("new-conv", in: dir)
        AntigravitySessions.groupPids = { _ in [11, 22] }
        defer { AntigravitySessions.groupPids = AntigravitySessions.procGroupPids }
        AntigravitySessions.vnodePaths = { pid in pid == 11 ? [old.path] : [new.path] }
        defer { AntigravitySessions.vnodePaths = AntigravitySessions.procVnodePaths }
        XCTAssertEqual(AntigravitySessions.session(forProcessGroup: 5, presence: dir), "new-conv")
    }

    func testNoOpenFdMeansNoSession() throws {
        let dir = try tempDir()
        _ = try lock("lingering", in: dir)
        AntigravitySessions.groupPids = { _ in [11] }
        defer { AntigravitySessions.groupPids = AntigravitySessions.procGroupPids }
        // The lock exists on disk but no fd of any group pid holds it.
        AntigravitySessions.vnodePaths = { _ in ["/tmp/other/lingering.lock", "/etc/hosts"] }
        defer { AntigravitySessions.vnodePaths = AntigravitySessions.procVnodePaths }
        XCTAssertNil(AntigravitySessions.session(forProcessGroup: 5, presence: dir))
        XCTAssertNil(AntigravitySessions.session(forProcessGroup: 5, presence: dir.appendingPathComponent("missing")))
    }

    // MARK: App conversation index (protobuf)

    private func fixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: nil)!
        return try! Data(contentsOf: url)
    }

    func testAgyHubSummariesParse() {
        let entries = AntigravityAppSessions.entries(fixture("agy-summaries.pb"))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].id, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(entries[0].title, "Write a haiku about tests")
        XCTAssertEqual(entries[0].workspaceURI, "file:///tmp/agy-fixture-ws")
        XCTAssertEqual(entries[0].updatedAt, Date(timeIntervalSince1970: 1_764_000_000))
        // An empty title falls back; a missing workspace is nil.
        XCTAssertEqual(entries[1].title, "Antigravity conversation")
        XCTAssertNil(entries[1].workspaceURI)
    }

    func testAgyHubSummariesTolerateTruncationAndJunk() {
        let good = fixture("agy-summaries.pb")
        var truncated = good
        truncated.removeLast(20)
        XCTAssertEqual(AntigravityAppSessions.entries(truncated).count, 1)
        XCTAssertEqual(AntigravityAppSessions.entries(Data("not protobuf".utf8)), [])
        XCTAssertEqual(AntigravityAppSessions.entries(good + Data([0xFF, 0xFF, 0xFF])), AntigravityAppSessions.entries(good))
    }

    // MARK: Tracker patterns from real agy screens

    /// agy's working state shows "Generating…/esc to cancel"; the prompt goes quiet to ">".
    /// From the real screens captured in the agy probe.
    func testAgyWorkingThenIdle() {
        var t = TerminalActivityTracker()
        t.noteOutput(bytes: 500, at: t0)
        let working = [" ⏺ OK", " Generating...", " esc to cancel", " accept-edits   Gemini 4 Neon   medium"]
        t.tick(now: t0.addingTimeInterval(5), screenTail: working)
        XCTAssertEqual(t.activity, .working)
        let idle = [" Conversation renamed to: Tessera Probe Agy", ">", " ? for shortcuts",
                    " accept-edits   Gemini 4 Neon   medium"]
        t.tick(now: t0.addingTimeInterval(6), screenTail: idle)
        // A turn that never raised attention settles quietly back to idle.
        XCTAssertEqual(t.activity, .idle)
    }

    /// agy's folder-trust chooser ("‣ Yes, I trust this folder / No, exit · Navigate · enter Confirm")
    /// is a question.
    func testAgyTrustChooserIsNeedsInput() {
        var t = TerminalActivityTracker()
        t.noteOutput(bytes: 500, at: t0)
        let screen = [" ✱ Do you trust the contents of this project?",
                      "   Antigravity requires permission to read, edit, and execute files here.",
                      " ‣ Yes, I trust this folder", "   No, exit", " Navigate · enter Confirm"]
        t.tick(now: t0.addingTimeInterval(5), screenTail: screen)
        XCTAssertEqual(t.activity, .needsInput)
        XCTAssertEqual(t.detail, "‣ Yes, I trust this folder")
    }

    // MARK: App model + rename

    func testAntigravityAppProperties() {
        XCTAssertEqual(AgentApp.antigravity.bundleID, "com.google.antigravity")
        XCTAssertEqual(AgentApp.antigravity.flavor, .antigravityDesktop)
        XCTAssertEqual(AgentApp.antigravity.name, "Antigravity app")
        XCTAssertTrue(AgentApp.antigravity.routesExistingSessions)
        XCTAssertFalse(AgentApp.antigravity.canCreateConversation)
        XCTAssertEqual(AgentApp.antigravity.newLabel, "Open Antigravity")
        XCTAssertNil(AgentApp.antigravity.conversationURL("x"))
    }

    func testAntigravityAppRenameRefusal() {
        guard case .unsupported(let reason) = RenameSupport.support(
            kind: .agentSession, flavor: .antigravityDesktop, agentRunning: false, sessionId: "c1") else {
            return XCTFail("expected unsupported")
        }
        XCTAssertEqual(reason, "This source can't be renamed: Antigravity app conversations have no supported way to rename them.")
    }
}
