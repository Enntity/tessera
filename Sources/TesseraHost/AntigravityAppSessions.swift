import Foundation
import TesseraKit

/// Reads `~/.gemini/antigravity/agyhub_summaries_proto.pb`, Antigravity.app's conversation index.
/// A minimal protobuf wire reader — varints and length-delimited fields only, unknown fields
/// skipped, truncation tolerated — because the summary file is small and its schema is stable:
/// repeated field 1 = entry {1: conversation id, 2: summary {1: title, 3: last modified
/// Timestamp {1: seconds, 2: nanos}, 7: created Timestamp, 9: workspace {1: file:// URI},
/// 10: last user input Timestamp}}.
enum AntigravityAppSessions {
    struct Entry: Equatable {
        var id: String
        var title: String
        /// The workspace's `file://` URI, when the summary records one.
        var workspaceURI: String?
        /// The summary's last-modified timestamp, when it parses.
        var updatedAt: Date?
    }

    /// Field data grouped by field number: varints and the bytes of length-delimited fields.
    /// Tolerates a torn tail (the writer may rewrite the file while we read).
    static func fields(_ data: Data) -> [Int: [Either]] {
        enum Tag {}
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

    /// One entry per top-level field 1 message: id (1) and its summary (2).
    static func entries(_ data: Data) -> [Entry] {
        fields(data)[1]?.compactMap { field -> Entry? in
            guard let entry = field.data else { return nil }
            let parts = fields(Data(entry))
            guard let id = parts[1]?.first?.string, !id.isEmpty else { return nil }
            var title = "Antigravity conversation", uri: String?, updated: Date?
            if let summary = parts[2]?.first?.data {
                let s = fields(Data(summary))
                if let t = s[1]?.first?.string, !t.isEmpty { title = t }
                if let ts = s[3]?.first?.data { updated = timestamp(ts) }
                if let ws = s[9]?.first?.data { uri = fields(Data(ws))[1]?.first?.string }
            }
            return Entry(id: id, title: title, workspaceURI: uri, updatedAt: updated)
        } ?? []
    }

    /// A `file://` URI's path, or the URI itself when it isn't one.
    static func folder(of uri: String) -> String {
        guard let url = URL(string: uri), url.isFileURL else { return uri }
        return url.path
    }
}
