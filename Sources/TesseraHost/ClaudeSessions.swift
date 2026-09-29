import Foundation
import TesseraKit

/// Claude Code writes each conversation to `~/.claude/projects/<folder-slug>/<session-id>.jsonl`
/// once the first message is sent.
enum ClaudeSessions {
    static var projects: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects") }

    static func transcriptExists(_ id: String) -> Bool {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(atPath: projects.path)) ?? []
        return dirs.contains { fm.fileExists(atPath: projects.appendingPathComponent($0).appendingPathComponent(id + ".jsonl").path) }
    }

    /// The working directory a transcript records (first `"cwd"` within its opening lines).
    static func recordedDirectory(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let text = String(decoding: handle.readData(ofLength: 256 * 1024), as: UTF8.self)
        for line in text.split(separator: "\n").prefix(200) {
            guard line.contains("\"cwd\""), let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let cwd = obj["cwd"] as? String else { continue }
            return cwd
        }
        return nil
    }

    /// Matches Claude tiles started without a known id (typed `claude`, launchers) to the transcript
    /// they created: same folder, created after the tile's agent started, not already claimed.
    static func bind(_ candidates: [CodexRollouts.Candidate], claimed: Set<String>) -> [String: String] {
        let fm = FileManager.default
        guard let earliest = candidates.map(\.launchedAt).min() else { return [:] }
        var fresh: [(id: String, created: Date, cwd: String)] = []
        for dir in (try? fm.contentsOfDirectory(atPath: projects.path)) ?? [] {
            let folder = projects.appendingPathComponent(dir)
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".jsonl") {
                let id = String(name.dropLast(6))
                guard SessionResume.isSafeId(id), !claimed.contains(id) else { continue }
                let path = folder.appendingPathComponent(name).path
                guard let created = (try? fm.attributesOfItem(atPath: path))?[.creationDate] as? Date,
                      created >= earliest.addingTimeInterval(-3),
                      let cwd = recordedDirectory(of: path) else { continue }
                fresh.append((id, created, URL(fileURLWithPath: cwd).standardizedFileURL.path))
            }
        }
        var taken = claimed
        var result: [String: String] = [:]
        for c in candidates.sorted(by: { $0.launchedAt < $1.launchedAt }) {
            let dir = URL(fileURLWithPath: c.cwd).standardizedFileURL.path
            let match = fresh
                .filter { !taken.contains($0.id) && $0.cwd == dir && $0.created >= c.launchedAt.addingTimeInterval(-3) }
                .min { $0.created < $1.created }
            if let match {
                result[c.tileId] = match.id
                taken.insert(match.id)
            }
        }
        return result
    }
}
