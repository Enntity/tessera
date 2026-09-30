import Foundation

/// Tessera's own JSON files in its data folder: the board, accounts and machines. Writes are atomic,
/// and a file that exists but can't be fully read (damaged, hand-edited, or written by a newer
/// Tessera) is never silently replaced: a copy is kept beside it as `<name>.unreadable-<date>` and
/// listed for a notice at launch.
@MainActor
public enum StateFile {
    /// Copies kept this launch.
    public private(set) static var keptAside: [URL] = []

    /// The file's contents; nil when there is none, or when it can't be decoded (a copy is kept).
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(T.self, from: data) { return value }
        keepAside(url)
        return nil
    }

    /// A saved list, minus entries this build can't read (a copy of the file is kept when any drop out).
    static func loadList<T: Decodable>(_ type: T.Type, from url: URL) -> [T]? {
        guard let entries = load([Lossy<T>].self, from: url) else { return nil }
        let values = entries.compactMap(\.value)
        if values.count < entries.count { keepAside(url) }
        return values
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: url, options: .atomic) }
    }

    /// Copies `url` aside before anything overwrites it.
    static func keepAside(_ url: URL) {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withFullDate, .withTime]
        stamp.timeZone = .current
        let copy = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).unreadable-\(stamp.string(from: Date()))")
        if (try? FileManager.default.copyItem(at: url, to: copy)) != nil { keptAside.append(copy) }
    }
}

/// A list entry that decodes to nil instead of failing the whole file (e.g. a tile kind from a newer Tessera).
struct Lossy<T: Decodable>: Decodable {
    var value: T?

    init(_ value: T) { self.value = value }
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension Lossy: Encodable where T: Encodable {
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
