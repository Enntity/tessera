import Foundation
import SQLite3
import TesseraKit

/// Where each agent's own store keeps a conversation's name — the origin of a tile's title. A read
/// that fails (missing file, locked database, parse error) yields nil, so callers keep the last
/// good value rather than flickering back.
enum OriginTitles {
    /// Claude Code: `/rename` writes a `custom-title` record into the session transcript
    /// (`~/.claude/projects/*/<sessionId>.jsonl`).
    static func claude(_ sessionId: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let root = home.appendingPathComponent(".claude/projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        for dir in dirs {
            let file = dir.appendingPathComponent(sessionId + ".jsonl")
            if let title = customTitle(in: file) { return title }
        }
        return nil
    }

    /// The last `{"type":"custom-title","customTitle":…}` record in a transcript's tail.
    static func customTitle(in file: URL, tail: Int = 65536) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > tail ? size - UInt64(tail) : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        var title: String?
        for line in text.split(separator: "\n") {
            guard line.contains("\"custom-title\""),
                  let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  record["type"] as? String == "custom-title",
                  let name = record["customTitle"] as? String, !name.isEmpty else { continue }
            title = name
        }
        return title
    }

    /// Codex: the `thread_name` column of `~/.codex/session_index.jsonl` (same store the watcher reads).
    static func codex(_ threadId: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let file = home.appendingPathComponent(".codex/session_index.jsonl")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var title: String?
        for line in text.split(separator: "\n") {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  record["id"] as? String == threadId else { continue }
            if let name = record["thread_name"] as? String, !name.isEmpty { title = name }
        }
        return title
    }

    /// Devin CLI: the `title` column of `sessions` in `~/.local/share/devin/cli/sessions.db`.
    static func devin(_ sessionId: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        sqlite("SELECT title FROM sessions WHERE id = ?1", sessionId,
               in: home.appendingPathComponent(".local/share/devin/cli/sessions.db").path)
    }

    /// Antigravity (`agy`): the `title` column of `conversation_summaries` in
    /// `~/.gemini/antigravity-cli/conversation_summaries.db`.
    static func agy(_ conversationId: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        sqlite("SELECT title FROM conversation_summaries WHERE conversation_id = ?1", conversationId,
               in: home.appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db").path)
    }

    /// One bound parameter, one text column, nil on any failure — a missing store is not an error.
    private static func sqlite(_ query: String, _ key: String, in path: String) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        let name = String(cString: text)
        return name.isEmpty ? nil : name
    }
}
