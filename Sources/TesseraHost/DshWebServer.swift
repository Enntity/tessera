import Foundation
import Observation
import TesseraKit

/// A `dsh web` server Tessera runs for opening DeepSeek Harness sessions: started on demand, on a
/// free port, without opening a browser. Its one-time token URL is captured so the first web tile
/// signs in automatically; the server stops when Tessera quits.
@Observable
@MainActor
public final class DshWebServer {
    public enum State: Equatable, Sendable {
        case stopped, starting, running, failed(String)
    }

    public private(set) var state: State = .stopped
    /// `http://127.0.0.1:<port>/`
    public private(set) var baseURL: URL?
    /// The token URL `dsh web` printed; opening it once sets the session cookie.
    public private(set) var launchURL: URL?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var waiters: [(Result<URL, DshError>) -> Void] = []
    @ObservationIgnored private var output = ""

    public struct DshError: Error, Sendable { public let message: String }

    public init() {}

    /// Calls back with the launch URL once the server is up (starting it if needed).
    public func ensureRunning(_ done: @escaping (Result<URL, DshError>) -> Void) {
        if case .running = state, let url = launchURL, process?.isRunning == true { return done(.success(url)) }
        waiters.append(done)
        guard state != .starting else { return }
        start()
    }

    private func start() {
        state = .starting
        output = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let probe = LoginShell.run(Self.probeScript)
            let resolved = probe.flatMap(Self.launcher(fromProbe:))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let (exe, args, path) = resolved else {
                        return self.finish(.failure(DshError(message: probe == nil
                            ? "Couldn't read your PATH: your login shell didn't finish starting."
                            : "dsh isn't installed. Install it with `npm i -g @deepseek-ai/dsh`, or make sure `npx` is on your PATH.")))
                    }
                    self.launch(exe, args: args + ["--profile", "web", "--no-open", "--port", "0"], path: path)
                }
            }
        }
    }

    /// Runs the server under a tiny shell watchdog that stops it (and npx's node child) if Tessera
    /// goes away without a clean quit, so a crash never leaves `dsh web` running.
    static let watchdog = """
    "$@" & c=$!
    stop() { pkill -TERM -P "$c" 2>/dev/null; kill -TERM "$c" 2>/dev/null; }
    trap 'stop; exit 0' TERM INT HUP
    while kill -0 "$TESSERA_PARENT_PID" 2>/dev/null && kill -0 "$c" 2>/dev/null; do sleep 2; done
    stop; wait "$c"
    """

    private func launch(_ exe: String, args: [String], path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", Self.watchdog, "dsh-web", exe] + args
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        for key in env.keys where key.hasPrefix("TESSERA_") { env.removeValue(forKey: key) }
        env["TESSERA_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(chunk) } }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.process === proc else { return }
                    self.process = nil
                    let tail = self.output.split(separator: "\n").suffix(2).joined(separator: " ").preview(160)
                    self.state = .failed("dsh web exited (\(proc.terminationStatus)). \(tail)")
                    self.finish(.failure(DshError(message: "dsh web exited before it was ready. \(tail)")))
                }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            finish(.failure(DshError(message: error.localizedDescription)))
            return
        }
        // First runs through npx download packages; give it time, then give up clearly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            MainActor.assumeIsolated {
                // Only this attempt: a retry started since has its own clock.
                guard let self, self.process === p, self.state == .starting else { return }
                self.stop()
                self.finish(.failure(DshError(message: "dsh web didn't start within two minutes.")))
            }
        }
    }

    private func consume(_ chunk: String) {
        output += chunk
        if output.count > 20_000 { output = String(output.suffix(10_000)) }
        guard state == .starting, let url = Self.launchURL(in: output) else { return }
        launchURL = url
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.query = nil
        baseURL = c?.url
        state = .running
        finish(.success(url))
    }

    private func finish(_ result: Result<URL, DshError>) {
        if case .failure(let e) = result { state = .failed(e.message) }
        let pending = waiters
        waiters = []
        for w in pending { w(result) }
    }

    public func stop() {
        guard let p = process else { return }
        process = nil
        p.terminate()
        state = .stopped
    }

    /// `dsh web: http://127.0.0.1:58070/?token=…` anywhere in the output.
    nonisolated static func launchURL(in text: String) -> URL? {
        guard let r = text.range(of: "dsh web: ") else { return nil }
        let rest = text[r.upperBound...].prefix { !$0.isWhitespace }
        guard let url = URL(string: String(rest)), url.scheme?.hasPrefix("http") == true,
              url.query?.contains("token=") == true else { return nil }
        return url
    }

    /// Asks the user's login shell for its PATH and where dsh and npx are, so version managers work.
    /// (Piped through sed, which reads the same in POSIX shells and fish.)
    nonisolated static let probeScript = "printenv PATH | /usr/bin/sed 's/^/@path /'; command -v dsh | /usr/bin/sed 's/^/@dsh /'; "
        + "command -v npx | /usr/bin/sed 's/^/@npx /'"

    /// The dsh (or npx) executable and PATH from the probe's output.
    nonisolated static func launcher(fromProbe output: String) -> (String, [String], String)? {
        guard let path = LoginShell.tagged("path", in: output).first, path.contains("/") else { return nil }
        if let dsh = LoginShell.tagged("dsh", in: output).first(where: { $0.hasPrefix("/") }) { return (dsh, [], path) }
        if let npx = LoginShell.tagged("npx", in: output).first(where: { $0.hasPrefix("/") }) { return (npx, ["-y", "@deepseek-ai/dsh"], path) }
        return nil
    }
}
