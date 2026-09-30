import Darwin
import Foundation

/// One Tessera per board: a second copy on the same data folder would resume every agent again and
/// fight over the saved board. The lock is an flock the kernel drops when the process exits (a crash
/// included); the file names the holder so a second copy can bring it forward.
enum BoardLock {
    /// Takes the lock for the life of this process and returns nil, or returns the pid of the process
    /// already holding it (0 if unknown). A folder that can't be locked never blocks a launch.
    static func take(in directory: URL) -> pid_t? {
        let fd = open(directory.appendingPathComponent("tessera.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let held = errno == EWOULDBLOCK
            var buf = [UInt8](repeating: 0, count: 16)
            let n = read(fd, &buf, buf.count)
            close(fd)
            guard held else { return nil }
            return pid_t(String(decoding: buf.prefix(max(n, 0)), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        // The descriptor stays open: the lock lasts as long as this process.
        let pid = Array("\(getpid())\n".utf8)
        ftruncate(fd, 0)
        _ = pwrite(fd, pid, pid.count, 0)
        return nil
    }
}
