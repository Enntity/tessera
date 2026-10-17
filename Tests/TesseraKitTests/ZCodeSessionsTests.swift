import Foundation
import SQLite3
import XCTest
@testable import TesseraHost
@testable import TesseraKit

final class ZCodeSessionsTests: XCTestCase {
    func testDiscoveryRequiresLocalLiveIndexAndReturnsBoundedTranscriptAndActivity() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tessera-zcode-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".enntity-zcode")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("v2"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cli"), withIntermediateDirectories: true)
        let dbURL = home.appendingPathComponent("synthetic-sessions.sqlite")
        let config = #"{"storage":{"sessionDbPath":"\#(dbURL.path)"}}"#
        try Data(config.utf8).write(to: root.appendingPathComponent("cli/config.json"))

        let now = Date()
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        try Self.database(root.appendingPathComponent("v2/tasks-index.sqlite"), sql: """
        CREATE TABLE tasks(workspace_key TEXT NOT NULL, workspace_path TEXT NOT NULL, workspace_identity TEXT, task_id TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', task_status TEXT, updated_at INTEGER NOT NULL, archived INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0, meta_json TEXT NOT NULL DEFAULT '{}', PRIMARY KEY(workspace_key,task_id));
        INSERT INTO tasks VALUES('/work/project','/work/project',NULL,'visible','Synthetic ZCode task','waiting',\(ms),0,0,'{"pendingInteraction":{"kind":"userInput"}}');
        INSERT INTO tasks VALUES('/work/project','/work/project',NULL,'archived','Archived task','completed',\(ms),1,0,'{}');
        INSERT INTO tasks VALUES('/work/project','/work/project',NULL,'deleted','Deleted task','completed',\(ms),0,1,'{}');
        INSERT INTO tasks VALUES('remote-key','/work/project','remote-key','remote','Remote task','running',\(ms),0,0,'{}');
        """)
        try Self.database(dbURL, sql: """
        CREATE TABLE session(id TEXT PRIMARY KEY, title TEXT NOT NULL, directory TEXT NOT NULL, time_updated INTEGER NOT NULL, time_archived INTEGER, parent_id TEXT);
        CREATE TABLE message(id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, sequence INTEGER, data TEXT NOT NULL);
        CREATE TABLE part(id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, sequence INTEGER, data TEXT NOT NULL);
        INSERT INTO session VALUES('visible','DB title','/work/project',\(ms),NULL,NULL);
        INSERT INTO session VALUES('archived','Archive','/work/project',\(ms),NULL,NULL);
        INSERT INTO session VALUES('deleted','Delete','/work/project',\(ms),NULL,NULL);
        INSERT INTO session VALUES('remote','Remote','/work/project',\(ms),NULL,NULL);
        INSERT INTO session VALUES('orphan','Unindexed','/work/project',\(ms),NULL,NULL);
        INSERT INTO session VALUES('child','Delegated','/work/project',\(ms),NULL,'visible');
        INSERT INTO message VALUES('u','visible',\(ms),1,'{"role":"user"}');
        INSERT INTO part VALUES('p2','u','visible',\(ms),1,'{"type":"text","text":"world"}');
        INSERT INTO part VALUES('p1','u','visible',\(ms),0,'{"type":"text","text":"Hello "}');
        INSERT INTO message VALUES('a','visible',\(ms),2,'{"role":"assistant"}');
        INSERT INTO part VALUES('p3','a','visible',\(ms),0,'{"type":"text","text":"Reply"}');
        """)

        let scanner = ZCodeSessionScanner(home: home, environment: [:])
        let sessions = scanner.scan(lookback: 3600, now: now)
        XCTAssertEqual(sessions.map(\.id), ["zcode:visible"])
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.title, "Synthetic ZCode task")
        XCTAssertEqual(session.cwd, "/work/project")
        XCTAssertEqual(session.snapshot.activity, .needsInput)
        XCTAssertEqual(session.snapshot.detail, "Input needed")
        XCTAssertEqual(session.snapshot.items.map(\.text), ["Hello world", "Reply"])
        XCTAssertEqual(session.snapshot.items.map(\.role), [.user, .assistant])

        let tile = TileInfo(id: session.id, kind: .agentSession, flavor: session.flavor, title: session.title)
        XCTAssertTrue(BoardQuery.Chip.zcode.holds(tile))
        XCTAssertFalse(BoardQuery.Chip.dsh.holds(tile))
        XCTAssertNil(AgentApp.opening(.zcodeDesktop, installed: [.zcode]))
        XCTAssertFalse(AgentApp.zcode.canCreateConversation)
    }

    func testActivityUsesFreshStatusAndIgnoresNullErrorAndStaleRunning() {
        let now = Date()
        let fresh = now.addingTimeInterval(-5)
        XCTAssertEqual(ZCodeSessionScanner.activity(status: "running", meta: ["lastError": NSNull()], updatedAt: fresh, now: now).activity, .working)
        XCTAssertEqual(ZCodeSessionScanner.activity(status: "error", meta: [:], updatedAt: fresh, now: now).activity, .failed)
        XCTAssertEqual(ZCodeSessionScanner.activity(status: "completed", meta: [:], updatedAt: fresh, now: now).activity, .done)
        XCTAssertEqual(ZCodeSessionScanner.activity(status: "running", meta: [:], updatedAt: now.addingTimeInterval(-3600), now: now).activity, .idle)
        XCTAssertEqual(ZCodeSessionScanner.activity(status: "running", meta: ["pendingInteraction": ["kind": "permission"]], updatedAt: fresh, now: now).activity, .needsInput)
    }

    private static func database(_ url: URL, sql: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &error)
        if code != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "SQLite fixture error"
            sqlite3_free(error)
            throw NSError(domain: "ZCodeSessionsTests", code: Int(code), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
