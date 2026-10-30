import Foundation
import TesseraKit

/// Devin leaves a lock per live session at `~/.local/share/devin/cli/session_locks/<id>.lock`
/// holding the pid of that session's `devin acp` child. The lock file lingers after the session
/// ends, so it only counts while its pid is still in the tile's foreground process group — which
/// names the tile's session exactly, with no folder or time guessing.
enum DevinSessions {
    static var locks: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("devin/cli/session_locks")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share/devin/cli/session_locks")
    }

    /// The session whose `devin acp` pid belongs to process group `pgid`; the newest lock when
    /// several match (a REPL can move between sessions inside one tile).
    static func session(forProcessGroup pgid: pid_t, locks: URL = locks) -> String? {
        let fm = FileManager.default
        var best: (id: String, modified: Date)?
        for name in (try? fm.contentsOfDirectory(atPath: locks.path)) ?? [] where name.hasSuffix(".lock") {
            let id = String(name.dropLast(".lock".count))
            guard SessionResume.isSafeId(id) else { continue }
            let path = locks.appendingPathComponent(name).path
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let pid = text.split(separator: "\n").first.flatMap({ Int32($0.trimmingCharacters(in: .whitespaces)) }),
                  pid > 0, getpgid(pid) == pgid else { continue }
            let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
            if best.map({ modified > $0.modified }) ?? true { best = (id, modified) }
        }
        return best?.id
    }
}
