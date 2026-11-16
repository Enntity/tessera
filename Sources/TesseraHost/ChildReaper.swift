import Foundation

/// Collects the exit of a child Tessera started in a terminal, so it leaves the process table.
/// SwiftTerm's `LocalProcess` asks for the status once, without waiting, when the child ends, and
/// stops watching altogether on `terminate()`: a child it never collected stays as a zombie until
/// Tessera quits.
enum ChildReaper {
    /// Waits for `pid` to end and collects it; one still running after `grace` is killed, with its
    /// process group, first. For a child nothing else will end or wait for.
    static func reap(_ pid: pid_t, grace: TimeInterval = 3) {
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            let deadline = Date().addingTimeInterval(grace)
            while Date() < deadline {
                if waitpid(pid, &status, WNOHANG) != 0 { return }
                usleep(100_000)
            }
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        }
    }
}
