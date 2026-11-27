import SQLite3
import XCTest
@testable import TesseraHost
@testable import TesseraKit

/// Antigravity's `agy` CLI: conversation detection, session ids, presence-lock binding and the
/// app's conversation stores — from the captured real screens in notes/antigravity-tessera-design.md.
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
        // agy 1.5 spells it -r and --resume too.
        XCTAssertEqual(SessionResume.sessionId(in: "agy -r 9464b4f1-4c0a"), "9464b4f1-4c0a")
        XCTAssertEqual(SessionResume.sessionId(in: "agy --resume 9464b4f1-4c0a"), "9464b4f1-4c0a")
        XCTAssertEqual(SessionResume.sessionId(in: "agy --resume=9464b4f1-4c0a"), "9464b4f1-4c0a")
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
        XCTAssertEqual(SessionResume.resumeCommand(original: "agy -r old --model m", sessionId: "new"), "agy --model m --conversation new")
        XCTAssertEqual(SessionResume.freshLaunch(original: "agy --resume=old --resume older"), "agy")
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

    // MARK: App conversations (conversation_summaries.db + conversations/<id>.db)

    /// A protobuf field, for building the app's step payloads.
    private indirect enum PB {
        case int(Int, UInt64), str(Int, String), msg(Int, [PB])
    }

    private func encode(_ fields: [PB]) -> Data {
        func varint(_ v: UInt64) -> Data {
            var v = v, out = Data()
            repeat { var b = UInt8(v & 0x7F); v >>= 7; if v > 0 { b |= 0x80 }; out.append(b) } while v > 0
            return out
        }
        func delimited(_ n: Int, _ d: Data) -> Data { varint(UInt64(n << 3 | 2)) + varint(UInt64(d.count)) + d }
        return fields.reduce(into: Data()) { out, f in
            switch f {
            case .int(let n, let v): out += varint(UInt64(n << 3)) + varint(v)
            case .str(let n, let s): out += delimited(n, Data(s.utf8))
            case .msg(let n, let sub): out += delimited(n, encode(sub))
            }
        }
    }

    private func sqlite(_ path: String, _ statements: [(String, [Any])]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw NSError(domain: "sqlite", code: 1) }
        defer { sqlite3_close(db) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (sql, binds) in statements {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw NSError(domain: "sqlite", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
            for (i, value) in binds.enumerated() {
                switch value {
                case let v as Int: sqlite3_bind_int64(stmt, Int32(i + 1), Int64(v))
                case let v as String: sqlite3_bind_text(stmt, Int32(i + 1), v, -1, transient)
                case let v as Data: _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, Int32(i + 1), $0.baseAddress, Int32(v.count), transient) }
                default: XCTFail("unsupported bind")
                }
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw NSError(domain: "sqlite", code: 3) }
            sqlite3_finalize(stmt)
        }
    }

    /// The app's summary table, as Antigravity 2.36 writes it (the columns Tessera reads).
    private func summaries(_ rows: [(id: String, title: String, preview: String, modified: String, ws: String,
                                     status: String, source: String, depth: Int, notIdle: Int)]) throws -> String {
        let path = try tempDir().appendingPathComponent("conversation_summaries.db").path
        try sqlite(path, [("""
            CREATE TABLE conversation_summaries (conversation_id text, title text NOT NULL DEFAULT "", preview text NOT NULL DEFAULT "",
            last_modified_time datetime NOT NULL, workspace_uris text NOT NULL, status text NOT NULL DEFAULT "",
            source text NOT NULL DEFAULT "", parent_conversation_id text NOT NULL DEFAULT "", nesting_depth integer NOT NULL DEFAULT 0,
            not_fully_idle numeric NOT NULL DEFAULT false, PRIMARY KEY (conversation_id))
            """, [])] + rows.map { r in
            ("INSERT INTO conversation_summaries VALUES (?,?,?,?,?,?,?,?,?,?)",
             [r.id, r.title, r.preview, r.modified, r.ws, r.status, r.source, r.depth > 0 ? "parent" : "", r.depth, r.notIdle])
        })
        return path
    }

    func testAppSummariesAreTheAppsOwnTopLevelConversations() throws {
        let path = try summaries([
            ("app-1", "Casual Greeting", "Casual Greeting", "2026-11-27 18:08:14.243191+00:00",
             #"["file:///Volumes/JMac%20External/ml"]"#, "CASCADE_RUN_STATUS_IDLE", "", 0, 0),
            ("app-2", "", "Audit the SparkLing work\nand more", "2026-11-27 17:00:00+00:00", "[]",
             "CASCADE_RUN_STATUS_RUNNING", "", 0, 0),
            ("app-3", "Busy", "", "2026-11-27 16:00:00+00:00", "[]", "CASCADE_RUN_STATUS_IDLE", "", 0, 1),
            // A CLI conversation belongs to its agy tile, a subagent to the conversation that ran it.
            ("cli-1", "", "How do I change thinking level", "2026-11-27 17:29:18+00:00", "[]",
             "CASCADE_RUN_STATUS_IDLE", "CORTEX_TRAJECTORY_SOURCE_CLI", 0, 0),
            ("sub-1", "", "", "2026-11-27 17:28:00+00:00", "[]", "CASCADE_RUN_STATUS_RUNNING", "", 1, 0)
        ])
        let found = try XCTUnwrap(AntigravityAppSessions.summaries(path))
        XCTAssertEqual(found.map(\.id), ["app-1", "app-2", "app-3"])
        XCTAssertEqual(found[0].title, "Casual Greeting")
        XCTAssertEqual(found[0].folder, "/Volumes/JMac External/ml")
        XCTAssertEqual(found[0].updatedAt.timeIntervalSince1970, 1_795_802_894.243, accuracy: 0.01)
        XCTAssertFalse(found[0].running)
        // Untitled: the first message stands in.
        XCTAssertEqual(found[1].title, "Audit the SparkLing work and more")
        XCTAssertEqual(found[1].folder, "")
        XCTAssertTrue(found[1].running)
        XCTAssertTrue(found[2].running, "not fully idle: background work is still going")
        XCTAssertNil(AntigravityAppSessions.summaries(path + "-missing"), "no store is no reading, not an empty list")
    }

    private func at(_ seconds: UInt64) -> PB { .msg(1, [.int(1, seconds)]) }

    private func steps(_ rows: [(type: Int, status: Int, payload: [PB])]) throws -> String {
        let path = try tempDir().appendingPathComponent("conv.db").path
        try sqlite(path, [("CREATE TABLE steps (idx integer, step_type integer NOT NULL DEFAULT 0, status integer NOT NULL DEFAULT 0, step_payload blob, PRIMARY KEY (idx))", [])]
                   + rows.enumerated().map { i, r in
            ("INSERT INTO steps VALUES (?,?,?,?)", [i, r.type, r.status, encode([.int(1, UInt64(r.type)), .int(4, UInt64(r.status))] + r.payload)])
        })
        return path
    }

    private let done = 3, canceled = 6, failed = 7, generating = 8, waiting = 9

    private func conversation(lastStatus: Int = 3, lastType: Int = 15) throws -> String {
        try steps([
            (14, done, [.msg(5, [at(100)]), .msg(19, [.str(2, "Audit the engine")])]),
            (101, done, [.msg(5, [at(101)]), .msg(114, [.str(1, "Reminder: work efficiently.")])]),
            (15, done, [.msg(5, [at(102)]), .msg(20, [.str(3, "Thinking about scope"),
                                                       .msg(7, [.str(1, "call_1"), .str(2, "run_command"), .str(3, "{}")])])]),
            (132, done, [.msg(5, [at(103), .msg(4, [.str(1, "call_1"), .str(2, "run_command"), .str(3, #"{"CommandLine":"ls -la"}"#)])])]),
            (132, failed, [.msg(5, [at(104), .msg(4, [.str(1, "call_2"), .str(2, "view_file"), .str(3, #"{"path":"x"}"#)])])]),
            (17, done, [.msg(5, [at(105)]), .msg(24, [.msg(3, [.str(2, "API error (attempt 1): context canceled by user")])])]),
            lastType == 132
                ? (132, lastStatus, [.msg(5, [at(106), .msg(4, [.str(1, "call_3"), .str(2, "run_command"), .str(3, #"{"CommandLine":"rm -rf build"}"#)])])])
                : (lastType, lastStatus, [.msg(5, [at(106)]), .msg(20, [.str(1, "The audit is done."), .str(8, "The audit is done.")]),
                                          .msg(24, [.msg(3, [.str(2, "Quota exhausted")])])])
        ])
    }

    func testAppTranscriptReadsMessagesToolsAndErrors() throws {
        let t = try XCTUnwrap(AntigravityAppSessions.transcript(try conversation()))
        XCTAssertEqual(t.items.map(\.role), [.user, .tool, .tool, .system, .assistant])
        XCTAssertEqual(t.items.map(\.text), ["Audit the engine", "ls -la", "x",
                                              "API error (attempt 1): context canceled by user", "The audit is done."])
        XCTAssertEqual(t.items.map(\.toolName), [nil, "run_command", "view_file", nil, nil])
        XCTAssertEqual(t.items.map(\.isError), [false, false, true, true, false])
        XCTAssertEqual(t.items.first?.timestamp, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(t.lastEventAt, Date(timeIntervalSince1970: 106))
        XCTAssertEqual(AntigravityAppSessions.describe(#"{"CommandLine":"ls","toolSummary":"List the repo"}"#), "List the repo")
        XCTAssertEqual(AntigravityAppSessions.describe(#"{"Query":"q"}"#), #"{"Query":"q"}"#)
        XCTAssertEqual(AntigravityAppSessions.transcript("/nonexistent/conv.db")?.items, [], "older conversations have no step store")
    }

    func testAppActivity() throws {
        let now = Date(timeIntervalSince1970: 200)
        func activity(_ path: String, running: Bool = false, appRunning: Bool = true) -> (TileActivity, String?) {
            let s = AntigravityAppSessions.snapshot(AntigravityAppSessions.transcript(path) ?? .init(), running: running,
                                                    appRunning: appRunning, updatedAt: now)
            return (s.activity, s.detail)
        }
        // A finished reply is a result to read.
        XCTAssertEqual(activity(try conversation()).0, .done)
        // A tool waiting on the developer is a question; only while the app is up to ask it.
        let asking = try conversation(lastStatus: waiting, lastType: 132)
        XCTAssertEqual(activity(asking).0, .needsInput)
        XCTAssertEqual(activity(asking).1, "Approve run_command")
        XCTAssertEqual(activity(asking, appRunning: false).0, .idle)
        // The run says it's going, or a step is still generating.
        XCTAssertEqual(activity(try conversation(), running: true).0, .working)
        XCTAssertEqual(activity(try conversation(lastStatus: generating)).0, .working)
        XCTAssertEqual(activity(try conversation(), running: true, appRunning: false).0, .done)
        // The turn ended on an error.
        let error = try conversation(lastType: 17)
        XCTAssertEqual(activity(error).0, .failed)
        XCTAssertEqual(activity(error).1, "Quota exhausted")
        // Canceled by the developer: nothing to read.
        XCTAssertEqual(activity(try conversation(lastStatus: canceled)).0, .idle)
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

    /// Signed out, agy opens on a login chooser: the tile waits on the developer, it isn't idle.
    func testAgySignInChooserIsNeedsInput() {
        var t = TerminalActivityTracker()
        t.noteOutput(bytes: 500, at: t0)
        let screen = [" Welcome back! You are currently not signed in.", "", " Select login method:",
                      " > 1. Continue with Google Cloud", "   2. Other sign-in options", "", "   ↑/↓ Navigate · enter Select"]
        t.tick(now: t0.addingTimeInterval(5), screenTail: screen)
        XCTAssertEqual(t.activity, .needsInput)
        XCTAssertEqual(t.detail, "Select login method:")
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
