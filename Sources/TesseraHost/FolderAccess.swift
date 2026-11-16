import Foundation

/// Gates a tile's spawn on macOS actually letting Tessera open its folder: after an update TCC can
/// hold every file open on a removable volume until a permission dialog is answered, and a child
/// spawned while it's held sits in shell startup forever. Reachable folders are cached for the app's
/// lifetime; a slow probe coalesces so callers queue behind the one in flight.
@MainActor enum FolderAccess {
    enum Outcome: Equatable { case reachable, denied(Int32) }

    /// Test seam: returns 0 or errno for opening `path`.
    static var opener = defaultOpener
    private static let defaultOpener: @Sendable (String) -> Int32 = { path in
        var fd: Int32
        repeat { fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC) } while fd < 0 && errno == EINTR
        if fd >= 0 { close(fd) }
        return fd < 0 ? errno : 0
    }

    private static var reachable: Set<String> = []
    private static var pending: [String: (probe: Probe, callbacks: [(Outcome) -> Void])] = [:]

    /// The outcome if known within `patience`; otherwise nil, and `done` is called on main once the
    /// folder can be opened (or is refused). A still-pending probe joins the same result.
    @discardableResult
    static func probe(_ path: String, patience: TimeInterval = 0.25, then done: @escaping @MainActor (Outcome) -> Void = { _ in }) -> Outcome? {
        if reachable.contains(path) { return .reachable }
        // A probe already in flight answers everyone at once; joining it never waits again.
        if var entry = pending[path] {
            entry.callbacks.append(done)
            pending[path] = entry
            return nil
        }
        let probe = Probe()
        pending[path] = (probe: probe, callbacks: [])
        let opener = opener
        DispatchQueue.global().async {
            let code = opener(path)
            let outcome: Outcome = code == EPERM || code == EACCES ? .denied(code) : .reachable
            probe.result.set(outcome)
            probe.semaphore.signal()
            DispatchQueue.main.async { finish(path, outcome) }
        }
        // The common case — the folder opens at once — stays synchronous.
        if probe.semaphore.wait(timeout: .now() + patience) == .success {
            return probe.result.outcome
        }
        var queued = pending[path]
        queued?.callbacks.append(done)
        pending[path] = queued
        return nil
    }

    /// Tests reset the seam and the caches between cases.
    static func reset() {
        pending.removeAll()
        reachable.removeAll()
        opener = defaultOpener
    }

    private static func finish(_ path: String, _ outcome: Outcome) {
        let callbacks = pending.removeValue(forKey: path)?.callbacks ?? []
        if outcome == .reachable { reachable.insert(path) }
        for callback in callbacks { callback(outcome) }
    }

    /// One open() in flight on a background queue; `semaphore` lets a synchronous caller wait out
    /// `patience`, `result` carries the outcome across.
    private final class Probe: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        let result = ProbeResult()
    }

    private final class ProbeResult: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Outcome = .reachable
        var outcome: Outcome { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ outcome: Outcome) { lock.lock(); stored = outcome; lock.unlock() }
    }
}
