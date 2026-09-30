import Foundation
import TesseraKit

/// Claude usage counted from the transcripts Claude Code and the Claude desktop app write locally —
/// always available, no sign-in needed. Tokens are input + output + cache writes (cache reads are
/// excluded; they're cheap and would swamp the number). Each API message counts once.
final class ClaudeLocalUsage: @unchecked Sendable {
    struct Totals: Equatable, Sendable {
        var tokens = 0
        var replies = 0
    }

    /// A plan limit Claude Code ran into (it records the refusal in the transcript): which window,
    /// and when it resets.
    struct Limit: Equatable, Sendable {
        var window: String
        var resetsAt: Date
    }

    private struct FileState {
        var offset: UInt64 = 0
        var remainder = Data()
        var seen: Set<String> = []
    }

    private var files: [String: FileState] = [:]
    /// Tokens and replies per hour since the epoch.
    private var hourly: [Int: Totals] = [:]
    private var limit: Limit?
    private let lock = NSLock()
    private let root: URL
    /// Transcripts are read this much at a time, so a first read of a huge one never holds it all.
    private let chunkSize: Int
    static let window: TimeInterval = 7 * 86_400

    /// Whether Claude Code has an account signed in (`~/.claude.json` names one once it has).
    static func signedIn(config: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")) -> Bool {
        guard let data = try? Data(contentsOf: config),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return root["oauthAccount"] != nil
    }

    init(root: URL = ClaudeSessions.projects, chunkSize: Int = 8 << 20) {
        self.root = root
        self.chunkSize = chunkSize
    }

    /// Reads whatever was appended since last time. Call off the main thread.
    func refresh(now: Date = Date()) -> (fiveHours: Totals, week: Totals, limit: Limit?) {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        var visited: Set<String> = []
        for dir in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let folder = root.appendingPathComponent(dir)
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".jsonl") {
                let path = folder.appendingPathComponent(name).path
                guard let stat = FileStat(path), now.timeIntervalSince(stat.modified) < Self.window else { continue }
                visited.insert(path)
                ingest(path: path, size: stat.size, since: now.addingTimeInterval(-Self.window))
            }
        }
        // Transcripts that left the window take their read state (and seen ids) with them.
        files = files.filter { visited.contains($0.key) }
        let hourNow = Int(now.timeIntervalSince1970 / 3600)
        hourly = hourly.filter { $0.key > hourNow - 24 * 7 - 1 }
        func sum(hours: Int) -> Totals {
            hourly.filter { $0.key > hourNow - hours }.values.reduce(into: Totals()) { acc, t in
                acc.tokens += t.tokens
                acc.replies += t.replies
            }
        }
        return (sum(hours: 5), sum(hours: 24 * 7), limit.flatMap { $0.resetsAt > now ? $0 : nil })
    }

    private func ingest(path: String, size: UInt64, since: Date) {
        var state = files[path] ?? FileState()
        if size < state.offset { state = FileState() }
        guard size > state.offset, let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: state.offset)
        // Chunk by chunk, each freed before the next.
        while autoreleasepool(invoking: {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
            var data = state.remainder
            data.append(chunk)
            state.offset += UInt64(chunk.count)
            if let lastNewline = data.lastIndex(of: 0x0A) {
                state.remainder = Data(data[(lastNewline + 1)...])
                // Byte-level scan: most of a transcript is tool output in user lines; only decode the
                // assistant lines that carry usage.
                Self.forEachLine(in: data[..<lastNewline], containing: ["\"type\":\"assistant\"", "\"usage\":{"]) { line in
                    count(line, into: &state, since: since)
                }
                Self.forEachLine(in: data[..<lastNewline], containing: [Self.limitKeys.refused]) { line in
                    if let hit = Self.limit(in: line), hit.resetsAt > limit?.resetsAt ?? .distantPast { limit = hit }
                }
            } else {
                state.remainder = data
            }
            return true
        }) {}
        if state.seen.count > 20_000 { state.seen.removeAll() }
        files[path] = state
    }

    /// Calls `body` with each newline-separated line (as raw bytes) that contains every needle.
    static func forEachLine(in data: Data, containing needles: [String], _ body: (UnsafeRawBufferPointer) -> Void) {
        let patterns = needles.map { Array($0.utf8) }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var start = 0
            let count = raw.count
            while start < count {
                let nl = memchr(base + start, 0x0A, count - start)
                let end = nl.map { base.distance(to: UnsafeRawPointer($0)) } ?? count
                let line = UnsafeRawBufferPointer(start: base + start, count: end - start)
                if !line.isEmpty, patterns.allSatisfy({ find($0, in: line, from: 0) != nil }) { body(line) }
                start = end + 1
            }
        }
    }

    static func find(_ needle: [UInt8], in line: UnsafeRawBufferPointer, from offset: Int) -> Int? {
        guard let base = line.baseAddress, offset < line.count else { return nil }
        return needle.withUnsafeBytes { n -> Int? in
            guard let hit = memmem(base + offset, line.count - offset, n.baseAddress, n.count) else { return nil }
            return base.distance(to: UnsafeRawPointer(hit))
        }
    }

    /// Bytes from `offset` up to (not including) the next `"`.
    static func quoted(in line: UnsafeRawBufferPointer, from offset: Int) -> String? {
        guard let base = line.baseAddress, offset < line.count,
              let q = memchr(base + offset, 0x22, line.count - offset) else { return nil }
        let end = base.distance(to: UnsafeRawPointer(q))
        return String(decoding: UnsafeRawBufferPointer(start: base + offset, count: end - offset), as: UTF8.self)
    }

    private static let limitKeys = (refused: "\"quotaLimits\":{\"status\":\"rejected\"", resetsAt: Array("\"resetsAt\":".utf8),
                                    window: Array("\"rateLimitType\":\"".utf8))

    private static func limit(in line: UnsafeRawBufferPointer) -> Limit? {
        guard let r = find(limitKeys.resetsAt, in: line, from: 0) else { return nil }
        let digits = String(decoding: UnsafeRawBufferPointer(rebasing: line[(r + limitKeys.resetsAt.count)...]).prefix { (0x30...0x39).contains($0) }, as: UTF8.self)
        guard let seconds = TimeInterval(digits) else { return nil }
        let window = find(limitKeys.window, in: line, from: 0).flatMap { quoted(in: line, from: $0 + limitKeys.window.count) }
        return Limit(window: window ?? "", resetsAt: Date(timeIntervalSince1970: seconds))
    }

    private static let assistantKeys = (usage: Array("\"usage\":{".utf8), timestamp: Array("\"timestamp\":\"".utf8),
                                        message: Array("\"message\":{".utf8), id: Array("\"id\":\"".utf8))

    /// Pulls just the id, timestamp and usage numbers out of a transcript line. Lines can be huge
    /// (whole replies and tool calls), so only these few small spans are ever decoded.
    private func count(_ line: UnsafeRawBufferPointer, into state: inout FileState, since: Date) {
        let keys = Self.assistantKeys
        guard let t = Self.find(keys.timestamp, in: line, from: 0),
              let ts = Self.quoted(in: line, from: t + keys.timestamp.count).flatMap(Self.date), ts >= since,
              let u = Self.find(keys.usage, in: line, from: 0) else { return }
        // Streaming writes one entry per content block, all carrying the same message and usage.
        if let m = Self.find(keys.message, in: line, from: 0), let i = Self.find(keys.id, in: line, from: m),
           let id = Self.quoted(in: line, from: i + keys.id.count) {
            guard state.seen.insert(id).inserted else { return }
        }
        // The usage object is small; balance braces from its start.
        var depth = 0, end = u + keys.usage.count - 1
        while end < line.count {
            let b = line[end]
            if b == 0x7B { depth += 1 } else if b == 0x7D { depth -= 1; if depth == 0 { break } }
            end += 1
        }
        let usage = Substring(String(decoding: UnsafeRawBufferPointer(rebasing: line[(u + keys.usage.count - 1)...min(end, line.count - 1)]), as: UTF8.self))
        let tokens = ["input_tokens", "output_tokens", "cache_creation_input_tokens"]
            .compactMap { Self.number(after: "\"\($0)\":", in: usage) }.reduce(0, +)
        let hour = Int(ts.timeIntervalSince1970 / 3600)
        hourly[hour, default: Totals()].tokens += tokens
        hourly[hour, default: Totals()].replies += 1
    }

    static func number(after key: String, in text: Substring) -> Int? {
        guard let r = text.range(of: key) else { return nil }
        return Int(text[r.upperBound...].prefix { $0.isNumber })
    }

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return fractional.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
