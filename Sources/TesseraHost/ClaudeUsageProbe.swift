import Foundation
import SwiftTerm
import TesseraKit

/// Reads the plan panel of Claude Code's own `/usage` command in a hidden terminal: Claude Code
/// starts as it would in any terminal (the user's settings and hooks as they are) in the home
/// folder, `/usage` is typed, the available quota windows are read as the panel settles, and Claude Code
/// is quit. No prompt is sent, so no model is asked anything and no conversation is saved; only
/// the user's own sign-in is used, by Claude Code itself. Runs only once the user has agreed.
@MainActor
final class ClaudeUsageProbe {
    enum Result: Equatable {
        case read([ClaudeUsageScreen.Window])
        case refused(String)
        /// Claude Code didn't show the panel in time (not installed, a prompt in the way).
        case failed(String)
    }

    private let mirror = TerminalMirror(cols: 120, rows: 60)
    private var process: LocalProcess?
    private var relay: Relay?
    private var timer: Timer?
    private var started = Date()
    private var askedAt: Date?
    private var windows: [ClaudeUsageScreen.Window] = []
    private var windowsChangedAt = Date.distantPast
    private var done: ((Result) -> Void)?
    private let executable: String
    private let args: [String]
    private let quitGrace: TimeInterval

    /// Tests stand a script in for Claude Code and shorten the wait for it to quit.
    init(executable: String = LoginShell.scriptShell(for: LoginShell.path), args: [String] = ["-l", "-i", "-c", "exec claude"],
         quitGrace: TimeInterval = 2) {
        self.executable = executable
        self.args = args
        self.quitGrace = quitGrace
    }

    func run(_ done: @escaping (Result) -> Void) {
        self.done = done
        started = Date()
        let relay = Relay(probe: self)
        self.relay = relay
        let process = LocalProcess(delegate: relay, dispatchQueue: .main)
        self.process = process
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        process.startProcess(executable: executable, args: args,
                             environment: environment.map { "\($0.key)=\($0.value)" }, execName: nil,
                             currentDirectory: NSHomeDirectory())
        guard process.shellPid > 0 else { return finish(.failed("Couldn't start Claude Code")) }
        process.closeMasterOnExec()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let lines = mirror.terminal.transcriptLines()
        let now = Date()
        if lines.contains(where: { $0.contains("Please run /login") || $0.contains("trust this folder") }) {
            return finish(.failed("Claude Code needs attention before it can show usage"))
        }
        guard let askedAt else {
            // Type /usage once Claude Code is waiting for input (its prompt is up), or after a while.
            if (lines.contains { $0.contains("❯") } && now.timeIntervalSince(started) > 2) || now.timeIntervalSince(started) > 12 {
                send("/usage")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    MainActor.assumeIsolated { self?.send("\r") }
                }
                self.askedAt = now
            }
            return
        }
        switch ClaudeUsageScreen.parse(Array(lines.suffix(80))) {
        case .windows(let windows):
            if windows != self.windows { self.windows = windows; windowsChangedAt = now }
            // Model-specific windows can appear after the overall weekly window.
            if now.timeIntervalSince(windowsChangedAt) >= 2 || now.timeIntervalSince(askedAt) > 20 { finish(.read(windows)) }
        case .refused(let why): finish(.refused(why))
        case nil where now.timeIntervalSince(askedAt) > 20: finish(.failed("Claude Code's usage panel didn't come up"))
        case nil: break
        }
    }

    private func send(_ text: String) { process?.send(data: ArraySlice(Array(text.utf8))) }

    private func finish(_ result: Result) {
        timer?.invalidate()
        timer = nil
        // Close the panel and quit; if Claude Code is slow to go, end it.
        send("\u{1b}")
        send("\u{3}")
        send("\u{3}")
        if let process, process.shellPid > 0 {
            let pid = process.shellPid
            DispatchQueue.main.asyncAfter(deadline: .now() + quitGrace) {
                var status: Int32 = 0
                // Gone and collected (by SwiftTerm, or just now): the pid is no longer ours to signal.
                guard waitpid(pid, &status, WNOHANG) == 0 else { return }
                // Ending it stops SwiftTerm watching for its exit, so collect it here.
                process.terminate()
                ChildReaper.reap(pid)
            }
        }
        process = nil
        let done = self.done
        self.done = nil
        done?(result)
    }

    fileprivate func received(_ slice: ArraySlice<UInt8>) { mirror.feed(Array(slice)) }

    /// LocalProcess holds its delegate weakly; the probe keeps this alive while it runs.
    private final class Relay: LocalProcessDelegate {
        weak var probe: ClaudeUsageProbe?
        init(probe: ClaudeUsageProbe) { self.probe = probe }
        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {}
        func dataReceived(slice: ArraySlice<UInt8>) { MainActor.assumeIsolated { probe?.received(slice) } }
        func getWindowSize() -> winsize { winsize(ws_row: 60, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0) }
    }
}
