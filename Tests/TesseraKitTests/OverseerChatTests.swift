import XCTest
@testable import TesseraHost
@testable import TesseraKit

@MainActor
final class OverseerChatTests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tessera-overseer-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func source(_ dir: URL, command: String? = "claude", sessionId: String? = "s-1") -> OverseerChat.Source {
        OverseerChat.Source(command: command, sessionId: sessionId, directory: dir)
    }

    /// A Claude transcript in `projects` for the overseer's folder.
    @discardableResult
    private func transcript(projects: URL, overseerDir: URL, sessionId: String = "s-1") throws -> URL {
        let folder = projects.appendingPathComponent(ClaudeSessions.projectFolder(for: overseerDir.path))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(sessionId + ".jsonl")
    }

    private func user(_ id: String, _ text: String) -> String {
        #"{"type":"user","uuid":""# + id + #"","message":{"role":"user","content":""# + text + #""}}"#
    }

    private func assistant(_ id: String, _ text: String) -> String {
        #"{"type":"assistant","uuid":""# + id + #"","message":{"stop_reason":"end_turn","content":[{"type":"text","text":""# + text + #""}]}}"#
    }

    private func write(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    /// The transcript's where the agent's folder says it should be, for a Claude overseer with a
    /// bound session — and nowhere for anything else.
    func testTranscriptPathIsTheBoundClaudeSession() throws {
        let dir = try tempDir()
        let projects = try tempDir()
        let path = OverseerChat.transcriptPath(source: source(dir), projects: projects)
        XCTAssertEqual(path, try transcript(projects: projects, overseerDir: dir).path)
        // No bound session, a non-Claude agent, an unsafe id: no transcript to show.
        XCTAssertNil(OverseerChat.transcriptPath(source: source(dir, sessionId: nil), projects: projects))
        XCTAssertNil(OverseerChat.transcriptPath(source: source(dir, command: "codex"), projects: projects))
        XCTAssertNil(OverseerChat.transcriptPath(source: source(dir, sessionId: "../x"), projects: projects))
    }

    /// A Claude overseer can have a transcript before the file exists: `hasTranscript` without a
    /// file, `latestReply`/`unread` once lines are there, `markSeen` persisted.
    func testChatReadsTheTranscript() throws {
        let dir = try tempDir()
        let projects = try tempDir()
        Preferences.store.removeObject(forKey: "tessera.overseerSeenReply")
        addTeardownBlock { Preferences.store.removeObject(forKey: "tessera.overseerSeenReply") }
        let chat = OverseerChat(projects: projects)
        let file = try transcript(projects: projects, overseerDir: dir)

        // The agent keeps a transcript even though nothing is written yet.
        chat.pollNow(source(dir))
        XCTAssertTrue(chat.hasTranscript)
        XCTAssertNil(chat.snapshot)
        XCTAssertNil(chat.latestReply)
        XCTAssertFalse(chat.unread)

        try write([user("u1", "What is going on?"), assistant("a1", "All quiet.")], to: file)
        chat.pollNow(source(dir))
        XCTAssertEqual(chat.snapshot?.items.count, 2)
        XCTAssertEqual(chat.latestReply?.id.hasPrefix("a1"), true)
        XCTAssertTrue(chat.unread)

        chat.markSeen()
        XCTAssertFalse(chat.unread)

        // What was seen stays seen (the seen id is persisted).
        let again = OverseerChat(projects: projects)
        again.pollNow(source(dir))
        XCTAssertEqual(again.latestReply?.id.hasPrefix("a1"), true)
        XCTAssertFalse(again.unread)

        // Appended lines are picked up incrementally.
        try append([user("u2", "And now?"), assistant("a2", "One tile is asking.")], to: file)
        again.pollNow(source(dir))
        XCTAssertEqual(again.latestReply?.id.hasPrefix("a2"), true)
        XCTAssertTrue(again.unread)
    }

    /// No bound session or a non-Claude agent: nothing to show.
    func testNoTranscriptWithoutABoundClaudeSession() throws {
        let dir = try tempDir()
        let chat = OverseerChat(projects: try tempDir())
        chat.pollNow(source(dir, sessionId: nil))
        XCTAssertFalse(chat.hasTranscript)
        chat.pollNow(source(dir, command: "cat"))
        XCTAssertFalse(chat.hasTranscript)
    }
}

extension OverseerChatTests {
    /// The overseer has left the grid for its panel but is still a board tile: out of
    /// `visibleIds`, still in `allTiles`, and its question still lands in the Needs-you queue.
    func testTheOverseerStaysOutOfTheGridButInTheQueue() throws {
        // Only a debug build takes its folder from the environment.
        #if !DEBUG
        throw XCTSkip("needs a debug build")
        #endif
        let dir = try tempDir()
        setenv("TESSERA_DATA_DIR", dir.path, 1)
        defer { unsetenv("TESSERA_DATA_DIR") }
        let workspace = Workspace()
        addTeardownBlock { @MainActor in workspace.prepareForQuit() }
        // Something that sits there asking (no real agent).
        workspace.overseerCommand = "sh -c 'printf \"Do you want to continue? (y/n) \"; read x'"
        workspace.start()
        let id = try XCTUnwrap(workspace.overseer())
        XCTAssertFalse(workspace.visibleIds.contains(id))
        XCTAssertTrue(workspace.allTiles.contains { $0.id == id })
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !workspace.state.queue.contains(id) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(workspace.state.queue.contains(id))
        XCTAssertFalse(workspace.visibleIds.contains(id))
    }
}

extension OverseerChatTests {
    /// A reply that lands while the panel is open is being looked at: not unread.
    func testAReplyArrivingWhileWatchingIsSeenAtOnce() throws {
        let dir = try tempDir()
        let projects = try tempDir()
        Preferences.store.removeObject(forKey: "tessera.overseerSeenReply")
        addTeardownBlock { Preferences.store.removeObject(forKey: "tessera.overseerSeenReply") }
        let file = try transcript(projects: projects, overseerDir: dir)
        let chat = OverseerChat(projects: projects)
        try write([user("u1", "Q"), assistant("a1", "First.")], to: file)
        chat.pollNow(source(dir))
        chat.markSeen()
        chat.watching = true
        try append([assistant("a2", "While you watch.")], to: file)
        chat.pollNow(source(dir))
        XCTAssertTrue(chat.latestReply?.id.hasPrefix("a2") ?? false)
        XCTAssertFalse(chat.unread)
        XCTAssertEqual(Preferences.store.string(forKey: "tessera.overseerSeenReply"), chat.latestReply?.id)
    }

    /// The board's counters don't hold the overseer: not a tab's tiles, not the chips, not the
    /// working count — but the lane's queue and needs-you set still have it.
    func testTheOverseerIsOutOfTheBoardCountsButInTheQueue() throws {
        // Only a debug build takes its folder from the environment.
        #if !DEBUG
        throw XCTSkip("needs a debug build")
        #endif
        let dir = try tempDir()
        setenv("TESSERA_DATA_DIR", dir.path, 1)
        defer { unsetenv("TESSERA_DATA_DIR") }
        let workspace = Workspace()
        addTeardownBlock { @MainActor in workspace.prepareForQuit() }
        workspace.overseerCommand = "sh -c 'while :; do printf \"⠋ esc to interrupt\\r\"; sleep 0.5; done'"
        workspace.start()
        let id = try XCTUnwrap(workspace.overseer())
        XCTAssertFalse(workspace.tabIds.contains(id))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, workspace.info(id)?.activity != .working {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(workspace.info(id)?.activity, .working)
        XCTAssertFalse(workspace.state.working.contains(id))
        XCTAssertFalse(workspace.holdings[.working]?.contains(id) ?? false)
        XCTAssertFalse(workspace.boardTiles.contains { $0.id == id })
        // And the queue-side counts keep it once it asks (see the asking test above).
    }
}
