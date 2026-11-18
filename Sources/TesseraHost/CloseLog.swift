import Foundation
import TesseraKit

/// One JSON line per record, appended to `<Tessera directory>/<file>` — the board's small
/// audit trail of what agents asked it to do and what happened. A file past 1 MB rotates
/// to `<file>.1`.
enum TileLog {
    static func append(in directory: URL, file: String, fields: [String: Any]) {
        guard let line = try? JSONSerialization.data(withJSONObject: fields) else { return }
        let url = directory.appendingPathComponent(file)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 1_000_000 { try? FileManager.default.moveItem(at: url, to: directory.appendingPathComponent(file + ".1")) }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(line)
            handle.write(Data("\n".utf8))
        } else {
            try? (line + Data("\n".utf8)).write(to: url)
        }
    }
}

/// Every tile close, appended to `closes.log` — who asked (the developer, or an agent and
/// its tile), how it ended, and why it was refused or needed approval.
enum CloseLog {
    static func append(in directory: URL, tile: String, title: String, kind: String, by: String,
                       outcome: String, reason: String? = nil, force: Bool = false) {
        var fields: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "tile": tile, "title": title,
                                   "kind": kind, "by": by, "outcome": outcome, "force": force]
        if let reason { fields["reason"] = reason }
        TileLog.append(in: directory, file: "closes.log", fields: fields)
    }
}

/// Every agent open or reopen, appended to `opens.log` — which agent, where, who asked, and
/// how it ended.
enum OpenLog {
    static func append(in directory: URL, tile: String? = nil, title: String, agent: String, cwd: String? = nil,
                       by: String, outcome: String, reason: String? = nil, resume: String? = nil, prompt: String? = nil) {
        var fields: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "title": title,
                                   "agent": agent, "by": by, "outcome": outcome]
        if let tile { fields["tile"] = tile }
        if let cwd { fields["cwd"] = cwd }
        if let reason { fields["reason"] = reason }
        if let resume { fields["resume"] = resume }
        if let prompt { fields["prompt"] = Redactor.redact(prompt).preview(200) }
        TileLog.append(in: directory, file: "opens.log", fields: fields)
    }
}
