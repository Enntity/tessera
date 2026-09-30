import Foundation
import TesseraKit

/// What the first line of a Codex rollout says about its session.
struct CodexRolloutHead: Sendable {
    var originator: String
    var id: String
    var cwd: String
    var isSubagent: Bool
    var startedAt: Date?

    var isDesktop: Bool { originator.localizedCaseInsensitiveContains("desktop") }
}

/// Codex writes every session (CLI or desktop) to `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
enum CodexRollouts {
    static var root: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions") }

    /// Rollouts modified within `lookback`, newest first.
    static func recentFiles(lookback: TimeInterval, now: Date = Date()) -> [(path: String, modified: Date)] {
        let fm = FileManager.default
        let cal = Calendar.current
        var files: [(String, Date)] = []
        for back in 0...max(1, Int(lookback / 86_400) + 1) {
            guard let day = cal.date(byAdding: .day, value: -back, to: now) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".jsonl") {
                let path = dir.appendingPathComponent(name).path
                if let modified = FileStat(path)?.modified, now.timeIntervalSince(modified) < lookback { files.append((path, modified)) }
            }
        }
        return files.sorted { $0.1 > $1.1 }
    }

    /// A rollout's head, read once: it never changes.
    static func head(_ path: String) -> CodexRolloutHead? { heads.head(path) }

    private static let heads = HeadCache()

    private final class HeadCache: @unchecked Sendable {
        private let lock = NSLock()
        private var heads: [String: CodexRolloutHead] = [:]

        func head(_ path: String) -> CodexRolloutHead? {
            if let hit = lock.withLock({ heads[path] }) { return hit }
            guard let head = autoreleasepool(invoking: { readHead(path) }) else { return nil }
            lock.withLock { heads[path] = head }
            return head
        }
    }

    /// Reads just the session_meta line; it can be large (it embeds instructions), so the read is capped.
    static func readHead(_ path: String) -> CodexRolloutHead? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 512 * 1024)
        guard let newline = data.firstIndex(of: 0x0A) else { return nil }
        var parser = CodexTranscriptParser()
        parser.ingest(line: Substring(String(decoding: data[..<newline], as: UTF8.self)))
        guard let originator = parser.originator, let id = parser.sessionId else { return nil }
        return CodexRolloutHead(originator: originator, id: id, cwd: parser.cwd ?? "", isSubagent: parser.isSubagent,
                                startedAt: parser.startedAt)
    }

    struct Candidate: Sendable {
        let tileId: String
        let cwd: String
        let launchedAt: Date
        /// The command continues an existing conversation (`resume --last`, `--continue`), so its
        /// session file predates the launch; match on being written after it instead.
        var continuing = false
    }

    /// Matches Codex CLI tiles to the rollouts they started: same folder, begun just after the tile
    /// launched, not a desktop or helper thread, and not already someone else's. Earliest wins.
    static func bind(_ candidates: [Candidate], claimed: Set<String>) -> [String: String] {
        let earliest = candidates.map(\.launchedAt).min() ?? Date()
        let heads: [(head: CodexRolloutHead, modified: Date)] = recentFiles(lookback: max(900, Date().timeIntervalSince(earliest) + 60))
            .compactMap { file in head(file.path).map { ($0, file.modified) } }
            .filter { !$0.head.isDesktop && !$0.head.isSubagent && SessionResume.isSafeId($0.head.id) && !claimed.contains($0.head.id) }
        var taken = claimed
        var result: [String: String] = [:]
        for c in candidates.sorted(by: { $0.launchedAt < $1.launchedAt }) {
            let dir = URL(fileURLWithPath: c.cwd).standardizedFileURL.path
            let since = c.launchedAt.addingTimeInterval(-3)
            let match = heads
                .filter { !taken.contains($0.head.id) && URL(fileURLWithPath: $0.head.cwd).standardizedFileURL.path == dir }
                .filter { ($0.head.startedAt ?? .distantPast) >= since || (c.continuing && $0.modified >= since) }
                .min { ($0.head.startedAt ?? .distantPast) < ($1.head.startedAt ?? .distantPast) }
            if let match {
                result[c.tileId] = match.head.id
                taken.insert(match.head.id)
            }
        }
        return result
    }
}
