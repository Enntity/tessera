import Foundation

/// What the kernel says about a process: its argv (to recognise an agent running in a shell
/// whose hooks never loaded) and its start time (to match the session file it wrote).
enum ProcessArgs {
    /// The process's argument vector, nil when it can't be read (gone, or another user's).
    static func argv(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        var words: [String] = []
        return buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, size >= MemoryLayout<Int32>.size else { return nil }
            let argc = base.load(as: Int32.self)
            var offset = MemoryLayout<Int32>.size
            // The executable's path comes first, then NUL padding up to the first argument.
            let end = size
            func string() -> String? {
                guard offset < end else { return nil }
                let start = offset
                while offset < end, buffer[offset] != 0 { offset += 1 }
                guard offset < end else { return nil }
                let word = String(decoding: buffer[start..<offset], as: UTF8.self)
                offset += 1
                return word
            }
            _ = string()
            while offset < end, buffer[offset] == 0 { offset += 1 }
            for _ in 0..<argc { guard let word = string() else { break }; words.append(word) }
            return words.isEmpty ? nil : words
        }
    }

    /// When the process started, for binding its session file to the right conversation.
    static func startTime(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }
}
