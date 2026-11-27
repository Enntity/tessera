import Foundation
import SQLite3
import TesseraKit

/// Antigravity.app's conversations, read-only, from `~/.gemini/antigravity`:
/// `conversation_summaries.db` lists them (title, workspace, run status) and
/// `conversations/<id>.db` holds each one's steps as protobuf payloads. The step schema, from the
/// app's own descriptors: every payload has {1: step type, 4: step status, 5: metadata {1: created
/// Timestamp, 4: tool call {1: id, 2: name, 3: JSON arguments}}}; a user input carries its text in
/// 19.2, a planner reply in 20.1 (its thinking in 20.3), an error message in 24.3.2.
enum AntigravityAppSessions {
    /// Field data grouped by field number: varints and the bytes of length-delimited fields.
    /// Tolerates a torn tail (the writer may rewrite the file while we read).
    static func fields(_ data: Data) -> [Int: [Either]] {
        var out: [Int: [Either]] = [:]
        var i = data.startIndex
        func varint() -> UInt64? {
            var value: UInt64 = 0, shift = 0
            while i < data.endIndex, shift < 64 {
                let b = data[i]; i = data.index(after: i)
                value |= UInt64(b & 0x7F) << UInt64(shift)
                if b & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while i < data.endIndex {
            guard let tag = varint(), tag > 0 else { break }
            let number = Int(tag >> 3), wire = Int(tag & 7)
            switch wire {
            case 0:
                guard let value = varint() else { return out }
                out[number, default: []].append(.varint(value))
            case 2:
                guard let length = varint(), length <= UInt64(data.endIndex - i) else { return out }
                out[number, default: []].append(.bytes(data[i..<data.index(i, offsetBy: Int(length))]))
                i = data.index(i, offsetBy: Int(length))
            case 1:
                guard data.endIndex - i >= 8 else { return out }
                i = data.index(i, offsetBy: 8)
            case 5:
                guard data.endIndex - i >= 4 else { return out }
                i = data.index(i, offsetBy: 4)
            default:
                return out
            }
        }
        return out
    }

    enum Either: Equatable {
        case varint(UInt64)
        case bytes(Data.SubSequence)
        var data: Data.SubSequence? { if case .bytes(let d) = self { return d }; return nil }
        var int: UInt64? { if case .varint(let v) = self { return v }; return nil }
        var string: String? { data.flatMap { String(data: Data($0), encoding: .utf8) } }
    }

    /// A Timestamp message {1: seconds, 2: nanos} as a Date.
    static func timestamp(_ data: Data.SubSequence) -> Date? {
        fields(Data(data))[1]?.first?.int.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    // MARK: Conversation list

    struct Summary: Equatable {
        var id: String
        var title: String
        /// The first workspace's folder, or "" when it has none.
        var folder: String
        var updatedAt: Date
        /// The run is going (running, busy, canceling) or background work is still holding it.
        var running: Bool
    }

    /// The app's own top-level conversations. A CLI conversation (source CLI) is its `agy` tile's,
    /// and a subagent's run belongs to the conversation that started it. Nil when the store
    /// can't be read right now (the app may be mid-write): not the same as no conversations.
    static func summaries(_ path: String) -> [Summary]? {
        guard let db = open(path) else { return nil }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT conversation_id, title, preview, (julianday(last_modified_time) - 2440587.5) * 86400.0,
                   workspace_uris, status, not_fully_idle
            FROM conversation_summaries
            WHERE source <> 'CORTEX_TRAJECTORY_SOURCE_CLI' AND nesting_depth = 0 AND parent_conversation_id = ''
            ORDER BY last_modified_time DESC LIMIT 200
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var out: [Summary] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            defer { rc = sqlite3_step(stmt) }
            guard let id = text(stmt, 0), SessionResume.isSafeId(id) else { continue }
            let title = [text(stmt, 1), text(stmt, 2)].compactMap { $0?.preview(80) }.first { !$0.isEmpty }
            let uris = text(stmt, 4).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] }
            let status = text(stmt, 5) ?? ""
            out.append(Summary(
                id: id, title: title ?? "Antigravity conversation", folder: uris?.first.map(folder) ?? "",
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                running: ["CASCADE_RUN_STATUS_RUNNING", "CASCADE_RUN_STATUS_BUSY", "CASCADE_RUN_STATUS_CANCELING"].contains(status)
                    || sqlite3_column_int(stmt, 6) != 0))
        }
        return rc == SQLITE_DONE ? out : nil
    }

    // MARK: One conversation's steps

    /// Step types and statuses (`CORTEX_STEP_TYPE_*`, `CORTEX_STEP_STATUS_*`).
    enum StepType { static let user = 14, reply = 15, error = 17, system = 101 }
    enum StepStatus {
        static let error = 7, waiting = 9
        static let inFlight: Set<Int> = [1, 2, 8, 11]  // pending, running, generating, queued
        static let stopped: Set<Int> = [6, 12]          // canceled, interrupted
    }

    struct Transcript: Equatable {
        var items: [ConversationItem] = []
        var lastEventAt: Date?
        /// The newest step that isn't a system reminder.
        var lastType: Int?
        var lastStatus: Int?
        /// A step is waiting on the developer (a tool to approve), and which tool.
        var waiting = false
        var waitingTool: String?
        /// A step is still pending, running, generating or queued.
        var inFlight = false
    }

    /// The conversation's latest steps, oldest first: what was said, the tools it ran, errors.
    /// Empty when it has no step store (older conversations); nil when the store can't be read now.
    static func transcript(_ path: String, steps limit: Int = 60) -> Transcript? {
        var t = Transcript()
        guard FileManager.default.fileExists(atPath: path) else { return t }
        guard let db = open(path) else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        // Bounded per step: the reader keeps what fits, so a huge tool output can't make each poll costly.
        let sql = "SELECT idx, step_type, status, substr(step_payload, 1, 262144) FROM steps WHERE step_type <> \(StepType.system) ORDER BY idx DESC LIMIT \(limit)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var rows: [(idx: Int64, type: Int, status: Int, payload: Data)] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            defer { rc = sqlite3_step(stmt) }
            let bytes = sqlite3_column_blob(stmt, 3), count = Int(sqlite3_column_bytes(stmt, 3))
            rows.append((sqlite3_column_int64(stmt, 0), Int(sqlite3_column_int(stmt, 1)), Int(sqlite3_column_int(stmt, 2)),
                         bytes.map { Data(bytes: $0, count: count) } ?? Data()))
        }
        guard rc == SQLITE_DONE else { return nil }
        t.lastType = rows.first?.type
        t.lastStatus = rows.first?.status
        for row in rows.reversed() {
            let step = fields(row.payload)
            let meta = step[5]?.first?.data.map { fields(Data($0)) } ?? [:]
            let at = meta[1]?.first?.data.flatMap(timestamp)
            if let at { t.lastEventAt = max(t.lastEventAt ?? at, at) }
            let call = meta[4]?.first?.data.map { fields(Data($0)) }
            if row.status == StepStatus.waiting { t.waiting = true; t.waitingTool = call?[2]?.first?.string ?? t.waitingTool }
            if StepStatus.inFlight.contains(row.status) { t.inFlight = true }
            func string(_ path: Int...) -> String? {
                var level = step
                for n in path.dropLast() { guard let d = level[n]?.first?.data else { return nil }; level = fields(Data(d)) }
                return path.last.flatMap { level[$0]?.first?.string }.flatMap { $0.isEmpty ? nil : String($0.prefix(4000)) }
            }
            let id = String(row.idx)
            switch row.type {
            case StepType.user:
                if let text = string(19, 2) { t.items.append(ConversationItem(id: id, role: .user, text: text, timestamp: at)) }
            case StepType.reply:
                if let text = string(20, 1) { t.items.append(ConversationItem(id: id, role: .assistant, text: text, timestamp: at)) }
            case StepType.error:
                if let text = string(24, 3, 2) {
                    t.items.append(ConversationItem(id: id, role: .system, text: text, isError: true, timestamp: at))
                }
            default:
                if let name = call?[2]?.first?.string, !name.isEmpty {
                    t.items.append(ConversationItem(id: id, role: .tool, text: String(describe(call?[3]?.first?.string ?? "").prefix(4000)),
                                                    toolName: name, isError: row.status == StepStatus.error, timestamp: at))
                }
            }
        }
        t.items = Array(t.items.suffix(20))
        return t
    }

    /// A tool call's arguments as a line: the app's own summary of it, else what it acts on.
    static func describe(_ arguments: String) -> String {
        guard let args = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else { return arguments }
        return ["toolSummary", "CommandLine", "Path", "path", "focus"].lazy.compactMap { args[$0] as? String }
            .first { !$0.isEmpty } ?? arguments
    }

    /// What the board shows for it. A step that waits or works only counts while the app is up to
    /// ask or work: a conversation left mid-run when the app quit is just idle.
    static func snapshot(_ t: Transcript, running: Bool, appRunning: Bool, updatedAt: Date) -> ConversationSnapshot {
        var activity = TileActivity.idle, detail: String?
        if appRunning, t.waiting {
            activity = .needsInput
            detail = t.waitingTool.map { "Approve \($0)" } ?? "Waiting for you"
        } else if appRunning, running || t.inFlight {
            activity = .working
        } else if t.lastType == StepType.error || t.lastStatus == StepStatus.error {
            activity = .failed
            detail = t.items.last(where: \.isError)?.text.preview(120)
        } else if let status = t.lastStatus, StepStatus.stopped.contains(status) {
            activity = .idle
        } else if t.items.last?.role == .assistant {
            activity = .done
        }
        if t.items.isEmpty, detail == nil { detail = "This conversation lives in the Antigravity app" }
        return ConversationSnapshot(items: t.items, activity: activity, detail: detail, lastEventAt: t.lastEventAt ?? updatedAt)
    }

    /// A `file://` URI's path, or the URI itself when it isn't one.
    static func folder(of uri: String) -> String {
        guard let url = URL(string: uri), url.isFileURL else { return uri }
        return url.path
    }

    private static func open(_ path: String) -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 150)
        return db
    }

    private static func text(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(stmt, column).map { String(cString: $0) }
    }
}
