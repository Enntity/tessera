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
                let modified = ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
                if now.timeIntervalSince(modified) < lookback { files.append((path, modified)) }
            }
        }
        return files.sorted { $0.1 > $1.1 }
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
    }

    /// Matches Codex CLI tiles to the rollouts they started: same folder, begun just after the tile
    /// launched, not a desktop or helper thread, and not already someone else's. Earliest wins.
    static func bind(_ candidates: [Candidate], claimed: Set<String>) -> [String: String] {
        let heads = recentFiles(lookback: 900).compactMap { readHead($0.path) }
            .filter { !$0.isDesktop && !$0.isSubagent && SessionResume.isSafeId($0.id) && !claimed.contains($0.id) }
        var taken = claimed
        var result: [String: String] = [:]
        for c in candidates.sorted(by: { $0.launchedAt < $1.launchedAt }) {
            let dir = URL(fileURLWithPath: c.cwd).standardizedFileURL.path
            let match = heads
                .filter { !taken.contains($0.id) && URL(fileURLWithPath: $0.cwd).standardizedFileURL.path == dir }
                .filter { ($0.startedAt ?? .distantPast) >= c.launchedAt.addingTimeInterval(-3) }
                .min { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
            if let match {
                result[c.tileId] = match.id
                taken.insert(match.id)
            }
        }
        return result
    }
}
