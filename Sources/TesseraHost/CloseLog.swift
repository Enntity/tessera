import Foundation

/// Every tile close, appended as one JSON line to `closes.log` in the Tessera data
/// directory — who asked (the developer, or an agent and its tile), how it ended, and
/// why it was refused or needed approval. The file rotates to `closes.log.1` past 1 MB.
enum CloseLog {
    static func append(in directory: URL, tile: String, title: String, kind: String, by: String,
                       outcome: String, reason: String? = nil, force: Bool = false) {
        var fields: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "tile": tile, "title": title,
                                   "kind": kind, "by": by, "outcome": outcome, "force": force]
        if let reason { fields["reason"] = reason }
        guard let line = try? JSONSerialization.data(withJSONObject: fields) else { return }
        let url = directory.appendingPathComponent("closes.log")
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 1_000_000 { try? FileManager.default.moveItem(at: url, to: directory.appendingPathComponent("closes.log.1")) }
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
