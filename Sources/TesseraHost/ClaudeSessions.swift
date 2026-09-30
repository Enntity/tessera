import Foundation
import TesseraKit

/// Claude Code writes each conversation to `~/.claude/projects/<folder-slug>/<session-id>.jsonl`
/// once the first message is sent.
enum ClaudeSessions {
    static var projects: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects") }

    /// Looks in `cwd`'s own project folder first, then in all of them.
    static func transcriptExists(_ id: String, cwd: String) -> Bool {
        let fm = FileManager.default
        func exists(in folder: String) -> Bool {
            fm.fileExists(atPath: projects.appendingPathComponent(folder).appendingPathComponent(id + ".jsonl").path)
        }
        return exists(in: projectFolder(for: cwd)) || ((try? fm.contentsOfDirectory(atPath: projects.path)) ?? []).contains(where: exists)
    }

    /// Claude Code's project folder name for a working directory (every non-alphanumeric → `-`).
    static func projectFolder(for cwd: String) -> String {
        String(URL(fileURLWithPath: cwd).standardizedFileURL.path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    /// The working directory a transcript records, and whether the desktop app wrote it.
    static func header(of path: String) -> (cwd: String, desktop: Bool)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let text = String(decoding: handle.readData(ofLength: 256 * 1024), as: UTF8.self)
        var cwd: String?
        var desktop = false
        for line in text.split(separator: "\n").prefix(200) {
            if line.contains("\"entrypoint\":\"claude-desktop\"") { desktop = true }
            if cwd == nil, line.contains("\"cwd\""), let data = line.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                cwd = obj["cwd"] as? String
            }
            if cwd != nil, desktop { break }
        }
        return cwd.map { ($0, desktop) }
    }

    /// Matches Claude tiles without a known id (typed `claude`, launchers, `--continue`) to their
    /// transcript: same folder, created after the tile's agent started (or, for a continue, written
    /// after it), not the desktop app's, not already claimed.
    static func bind(_ candidates: [CodexRollouts.Candidate], claimed: Set<String>) -> [String: String] {
        let fm = FileManager.default
        var taken = claimed
        var result: [String: String] = [:]
        for c in candidates.sorted(by: { $0.launchedAt < $1.launchedAt }) {
            let dir = URL(fileURLWithPath: c.cwd).standardizedFileURL.path
            let since = c.launchedAt.addingTimeInterval(-3)
            // Look in the folder's own project directory first; fall back to all of them.
            let preferred = projects.appendingPathComponent(projectFolder(for: dir))
            let folders = fm.fileExists(atPath: preferred.path)
                ? [preferred]
                : ((try? fm.contentsOfDirectory(atPath: projects.path)) ?? []).map { projects.appendingPathComponent($0) }
            var best: (id: String, created: Date)?
            for folder in folders {
                for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".jsonl") {
                    let id = String(name.dropLast(6))
                    guard SessionResume.isSafeId(id), !taken.contains(id) else { continue }
                    let path = folder.appendingPathComponent(name).path
                    guard let attrs = try? fm.attributesOfItem(atPath: path),
                          let created = attrs[.creationDate] as? Date, let modified = attrs[.modificationDate] as? Date,
                          created >= since || (c.continuing && modified >= since),
                          let head = header(of: path), !head.desktop,
                          URL(fileURLWithPath: head.cwd).standardizedFileURL.path == dir else { continue }
                    if best == nil || created < best!.created { best = (id, created) }
                }
            }
            if let best {
                result[c.tileId] = best.id
                taken.insert(best.id)
            }
        }
        return result
    }
}
