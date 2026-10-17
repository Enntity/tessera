import Foundation
import SQLite3
import TesseraKit

/// Read-only bridge to the Enntity ZCode task index and CLI session store.
/// The task index is the product-owned allowlist; an unindexed ~/.zcode session is never shown.
struct ZCodeSessionScanner {
    private let home: URL
    private let environment: [String: String]
    private let fileManager = FileManager.default

    init(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        self.environment = environment
    }

    private var dataBaseDir: URL {
        if let raw = environment["ZCODE_DATA_BASE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        let settings = home.appendingPathComponent(".enntity-zcode/v2/setting.json")
        if let data = try? Data(contentsOf: settings),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let raw = root["dataBaseDir"] as? String, !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home
    }

    var configURL: URL { dataBaseDir.appendingPathComponent(".enntity-zcode/cli/config.json") }
    var taskIndexURL: URL { dataBaseDir.appendingPathComponent(".enntity-zcode/v2/tasks-index.sqlite") }

    /// The fork config may point to an explicitly selected session store. Relative paths are
    /// resolved against each workspace, matching ZCode's bootstrap session-store behavior.
    private func configuredSessionPath(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let storage = root["storage"] as? [String: Any],
              let raw = storage["sessionDbPath"] as? String, !raw.isEmpty else { return nil }
        return raw
    }

    private func sessionDatabaseURL(for workspace: String, configuredPath: String?, base: URL) -> URL {
        if let raw = configuredPath {
            let expanded = (raw as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
            return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: workspace, isDirectory: true)).standardizedFileURL
        }
        let fork = base.appendingPathComponent(".enntity-zcode/cli/db/db.sqlite")
        if fileManager.fileExists(atPath: fork.path) { return fork }
        // Older fork builds kept the session store at ZCode's source default. It is safe to inspect
        // only because a matching Enntity task-index row below is mandatory for every surfaced ID.
        return home.appendingPathComponent(".zcode/cli/db/db.sqlite")
    }

    func scan(lookback: TimeInterval, now: Date) -> [AgentAppSession] {
        let base = dataBaseDir
        let indexRows = Self.readTaskIndex(base.appendingPathComponent(".enntity-zcode/v2/tasks-index.sqlite"))
        guard !indexRows.isEmpty else { return [] }
        let configPath = configuredSessionPath(base.appendingPathComponent(".enntity-zcode/cli/config.json"))
        let grouped = Dictionary(grouping: indexRows) { sessionDatabaseURL(for: $0.workspacePath, configuredPath: configPath, base: base).path }
        var found: [String: AgentAppSession] = [:]
        for rowsForStore in grouped.values {
            guard let first = rowsForStore.first else { continue }
            let database = sessionDatabaseURL(for: first.workspacePath, configuredPath: configPath, base: base)
            guard fileManager.fileExists(atPath: database.path), let db = Self.openReadOnly(database) else { continue }
            defer { sqlite3_close(db) }
            let rowsByKey = Dictionary(rowsForStore.map { (Self.joinKey($0.taskID, $0.workspacePath), $0) },
                                       uniquingKeysWith: { first, _ in first })
            let sessions = Self.readSessions(db, ids: Array(rowsForStore.map(\.taskID).uniqued().prefix(50)))
            let candidates = sessions.compactMap { row -> (SessionRow, TaskRow)? in
                guard let task = rowsByKey[Self.joinKey(row.id, row.directory)],
                      now.timeIntervalSince(row.updatedAt) < lookback,
                      now.timeIntervalSince(row.updatedAt) >= -60 else { return nil }
                return (row, task)
            }
            let transcript = Self.readTranscript(db, sessionIDs: candidates.map { $0.0.id })
            for (row, task) in candidates {
                let items = transcript[row.id] ?? []
                let state = Self.activity(status: task.status, meta: task.meta, updatedAt: task.updatedAt, now: now)
                let title = task.title.isEmpty ? row.title : task.title
                found[row.id] = AgentAppSession(id: "zcode:" + row.id, flavor: .zcodeDesktop,
                                                title: title.isEmpty ? "Enntity ZCode task" : title,
                                                cwd: row.directory, openURL: nil, resumeCommand: nil,
                                                snapshot: ConversationSnapshot(items: items, activity: state.activity,
                                                                               detail: state.detail,
                                                                               lastEventAt: row.updatedAt),
                                                summary: nil, lastActivityAt: max(row.updatedAt, task.updatedAt))
            }
        }
        return found.values.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    private struct SessionRow {
        let id: String
        let title: String
        let directory: String
        let updatedAt: Date
        let archivedAt: Date?
        let parentID: String?
    }

    private struct TaskRow {
        let taskID: String
        let workspacePath: String
        let workspaceIdentity: String?
        let title: String
        let status: String?
        let meta: [String: Any]
        let updatedAt: Date
    }

    private static func joinKey(_ id: String, _ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path + "\u{0}" + id
    }

    private static func openReadOnly(_ url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 150)
        return db
    }

    private static func readTaskIndex(_ url: URL) -> [TaskRow] {
        guard FileManager.default.fileExists(atPath: url.path), let db = openReadOnly(url) else { return [] }
        defer { sqlite3_close(db) }
        let sql = "SELECT workspace_path, workspace_identity, task_id, title, task_status, meta_json, updated_at FROM tasks WHERE archived = 0 AND deleted = 0 AND (workspace_identity IS NULL OR workspace_identity = '') ORDER BY updated_at DESC LIMIT 500"
        guard let stmt = prepare(db, sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [TaskRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let identity = text(stmt, 1)
            // A remote task may reuse a local path. Tessera has no live remote workspace identity,
            // so only index rows keyed by a plain local path are eligible for this local scanner.
            guard identity?.isEmpty != false else { continue }
            let metaText = text(stmt, 5) ?? "{}"
            let meta = ((try? JSONSerialization.jsonObject(with: Data(metaText.utf8))) as? [String: Any]) ?? [:]
            rows.append(TaskRow(taskID: text(stmt, 2) ?? "", workspacePath: text(stmt, 0) ?? "",
                                workspaceIdentity: identity, title: text(stmt, 3) ?? "", status: text(stmt, 4), meta: meta,
                                updatedAt: date(stmt, 6)))
        }
        return rows
    }

    private static func readSessions(_ db: OpaquePointer, ids: [String]) -> [SessionRow] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = "SELECT id, title, directory, time_updated, time_archived, parent_id FROM session WHERE id IN (\(placeholders)) AND parent_id IS NULL AND time_archived IS NULL ORDER BY time_updated DESC LIMIT 500"
        guard let stmt = prepare(db, sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(ids, to: stmt)
        var rows: [SessionRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(SessionRow(id: text(stmt, 0) ?? "", title: text(stmt, 1) ?? "",
                                   directory: text(stmt, 2) ?? "", updatedAt: date(stmt, 3),
                                   archivedAt: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : date(stmt, 4),
                                   parentID: text(stmt, 5)))
        }
        return rows
    }

    private static func readTranscript(_ db: OpaquePointer, sessionIDs: [String]) -> [String: [ConversationItem]] {
        guard !sessionIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ",")
        let sql = "WITH ranked_messages AS (SELECT m.id, m.session_id, m.data, m.time_created, m.sequence, row_number() OVER (PARTITION BY m.session_id ORDER BY m.sequence IS NULL, m.sequence DESC, m.time_created DESC, m.id DESC) AS n FROM message m WHERE m.session_id IN (\(placeholders))), ranked_parts AS (SELECT p.id, p.message_id, p.data, p.time_created, p.sequence, row_number() OVER (PARTITION BY p.message_id ORDER BY p.sequence IS NULL, p.sequence, p.time_created, p.id) AS n FROM part p JOIN ranked_messages m ON m.id = p.message_id WHERE m.n <= 20) SELECT m.id, m.session_id, json_extract(m.data, '$.role'), m.time_created, json_extract(p.data, '$.type'), json_extract(p.data, '$.ignored'), substr(json_extract(p.data, '$.text'), 1, 3000), m.sequence FROM ranked_messages m LEFT JOIN ranked_parts p ON p.message_id = m.id AND p.n <= 16 WHERE m.n <= 20 ORDER BY m.session_id, m.sequence IS NULL, m.sequence, m.time_created, m.id, p.sequence IS NULL, p.sequence, p.time_created, p.id"
        guard let stmt = prepare(db, sql) else { return [:] }
        defer { sqlite3_finalize(stmt) }
        bind(sessionIDs, to: stmt)

        struct ItemKey: Hashable { let session: String; let message: String }
        var grouped: [ItemKey: (role: ConversationItem.Role, date: Date, sequence: Int64?, text: [String])] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let messageID = text(stmt, 0), let sessionID = text(stmt, 1),
                  let roleName = text(stmt, 2), let role = role(roleName) else { continue }
            let key = ItemKey(session: sessionID, message: messageID)
            let sequence = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 7)
            var value = grouped[key] ?? (role, date(stmt, 3), sequence, [])
            if text(stmt, 4) == "text", sqlite3_column_int(stmt, 5) == 0,
               let content = text(stmt, 6), !content.isEmpty {
                value.text.append(content)
            }
            grouped[key] = value
        }
        var result: [String: [ConversationItem]] = [:]
        for (key, value) in grouped where !value.text.isEmpty {
            result[key.session, default: []].append(ConversationItem(id: key.message, role: value.role,
                                                                     text: value.text.joined(),
                                                                     timestamp: value.date))
        }
        for id in result.keys {
            let sequences = grouped.reduce(into: [String: Int64]()) { result, entry in
                if entry.key.session == id { result[entry.key.message] = entry.value.sequence ?? Int64.max }
            }
            result[id] = Array(result[id, default: []].sorted {
                let left = sequences[$0.id] ?? Int64.max
                let right = sequences[$1.id] ?? Int64.max
                if left != right { return left < right }
                if $0.timestamp != $1.timestamp { return ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
                return $0.id < $1.id
            }.suffix(20))
        }
        return result
    }

    static func activity(status: String?, meta: [String: Any], updatedAt: Date, now: Date) -> (activity: TileActivity, detail: String?) {
        if let pending = meta["pendingInteraction"] as? [String: Any],
           let kind = pending["kind"] as? String {
            return (.needsInput, kind == "permission" ? "Permission needed" : "Input needed")
        }
        if let error = meta["lastError"], !(error is NSNull) { return (.failed, "Task failed") }
        switch status?.lowercased() {
        case "running", "waiting", "paused":
            guard now.timeIntervalSince(updatedAt) <= 15 * 60 else { return (.idle, nil) }
            return (.working, nil)
        case "completed": return (.done, nil)
        case "error", "failed", "errored": return (.failed, "Task failed")
        default: break
        }
        return (.idle, nil)
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }

    private static func bind(_ values: [String], to stmt: OpaquePointer) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), value, -1, transient)
        }
    }

    private static func role(_ raw: String) -> ConversationItem.Role? {
        switch raw { case "user": .user; case "assistant": .assistant; default: nil }
    }

    private static func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: raw)
    }

    private static func date(_ stmt: OpaquePointer, _ column: Int32) -> Date {
        Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, column)) / 1000)
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
