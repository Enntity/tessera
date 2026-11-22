import Foundation
import TesseraKit

/// A running `agy` holds `~/.gemini/antigravity-cli/presence/<conversationId>.lock` open for the
/// conversation its REPL is in. The lock files are empty and linger after exit, so only an open
/// vnode fd counts. The newest lock mtime wins when several pids in the tile's foreground match
/// (a `/resume` can move one REPL between conversations), like Devin's session locks.
enum AntigravitySessions {
    static var presence: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/antigravity-cli/presence")
    }

    /// Test seams: the kernel queries are injectable so selection logic is unit-tested.
    static var groupPids: (pid_t) -> [pid_t] = AntigravitySessions.procGroupPids
    static var vnodePaths: (pid_t) -> [String] = AntigravitySessions.procVnodePaths

    /// The conversation whose presence lock some pid of process group `pgid` holds open.
    static func session(forProcessGroup pgid: pid_t, presence: URL = presence) -> String? {
        let fm = FileManager.default
        var best: (id: String, modified: Date)?
        for pid in groupPids(pgid) {
            for path in vnodePaths(pid) {
                guard path.hasPrefix(presence.path + "/"), path.hasSuffix(".lock") else { continue }
                let id = String(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                guard SessionResume.isSafeId(id) else { continue }
                let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
                if best.map({ modified > $0.modified }) ?? true { best = (id, modified) }
            }
        }
        return best?.id
    }

    /// Every pid in process group `pgid`.
    static func procGroupPids(_ pgid: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 256)
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(bitPattern: pgid), &pids,
                                Int32(MemoryLayout<pid_t>.size * pids.count))
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    /// The paths of every vnode fd `pid` holds open.
    static func procVnodePaths(_ pid: pid_t) -> [String] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        guard got > 0 else { return [] }
        var out: [String] = []
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info,
                                 Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else { continue }
            let path = withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            out.append(path)
        }
        return out
    }
}
