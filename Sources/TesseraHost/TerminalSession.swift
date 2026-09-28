import AppKit
import Foundation
import Observation
import SwiftTerm
import TesseraKit

/// One PTY-backed tile. The SwiftTerm view is created once and lives for the session: it is the
/// screen state for thumbnails, and it is re-parented into the expanded panel when opened, so
/// nothing is replayed and nothing is lost.
@Observable
@MainActor
public final class TerminalSession: NSObject {
    public let id: String
    /// What the user launched (never rewritten with session flags); resume commands derive from it.
    public var command: String?
    public var cwd: String
    /// The agent conversation this tile is in, when known (assigned at launch, parsed from the
    /// command, or bound from the tool's session log).
    public private(set) var sessionId: String?
    /// Shut down by the user (or restored that way); Resume brings the conversation back.
    public private(set) var isSuspended = false
    /// With no known session id, may resuming fall back to the tool's "continue latest"?
    /// Only one tile per tool and folder should, or they'd all attach to the same conversation.
    @ObservationIgnored public var mayContinueLatest = true
    @ObservationIgnored public private(set) var launchedAt = Date()
    @ObservationIgnored private var hasStarted = false
    public let flavor: AgentFlavor
    public private(set) var title: String
    public var customTitle: String?
    public private(set) var info: TileInfo
    /// Bumped (throttled) when the screen changes; drives thumbnail redraws.
    public private(set) var revision = 0

    @ObservationIgnored public let view: TerminalView
    @ObservationIgnored private var process: LocalProcess?
    /// LocalProcess only holds its delegate weakly; the session owns it.
    @ObservationIgnored private var relay: ProcessRelay?
    /// Each start gets its own process and relay; callbacks from an older generation are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var tracker = TerminalActivityTracker()
    @ObservationIgnored private var dirty = false
    /// When output last arrived; screens that have been still for a while need no rescanning.
    @ObservationIgnored private var lastOutputAt: Date = .distantPast
    @ObservationIgnored private var settledScanDone = false
    @ObservationIgnored private var progress: Double?
    @ObservationIgnored public private(set) var isRunning = false
    /// Raw output fan-out for remote clients.
    @ObservationIgnored public var outputObservers: [UUID: ([UInt8]) -> Void] = [:]

    static let defaultFont = NSFont(name: "SFMono-Regular", size: 12.5) ?? .monospacedSystemFont(ofSize: 12.5, weight: .regular)

    /// `label` names the tile until the program sets its own title (defaults to the command);
    /// `title` is a user-chosen name that always wins.
    public init(id: String = UUID().uuidString, command: String?, cwd: String, title: String? = nil, label: String? = nil,
                sessionId: String? = nil, resuming: Bool = false, mayContinueLatest: Bool = true, startSuspended: Bool = false,
                initialSize: CGSize = CGSize(width: 1180, height: 740)) {
        self.id = id
        self.command = command
        self.cwd = cwd
        self.sessionId = sessionId ?? command.flatMap(SessionResume.sessionId(in:))
        self.hasStarted = resuming
        self.mayContinueLatest = mayContinueLatest
        self.flavor = AgentFlavor.infer(fromCommand: command)
        let initial = title ?? label ?? command ?? "Shell"
        self.title = initial
        self.customTitle = title
        self.view = TerminalView(frame: CGRect(origin: .zero, size: initialSize), font: Self.defaultFont)
        self.info = TileInfo(id: id, kind: .terminal, flavor: flavor, title: initial, subtitle: cwd.abbreviatingHome)
        super.init()
        configureView()
        if startSuspended {
            isSuspended = true
            tracker.noteSuspended(resumeHint: resumeHint)
            refreshInfo()
        } else {
            start()
        }
    }

    private func configureView() {
        let theme = TerminalTheme.midnight
        view.terminalDelegate = self
        view.nativeBackgroundColor = NSColor(cgColor: theme.background.cgColor) ?? .black
        view.nativeForegroundColor = NSColor(cgColor: theme.foreground.cgColor) ?? .white
        view.caretColor = NSColor(cgColor: theme.cursor.cgColor) ?? .cyan
        view.installColors(theme.ansi.map { SwiftTerm.Color(red: UInt16($0.r) * 257, green: UInt16($0.g) * 257, blue: UInt16($0.b) * 257) })
        view.optionAsMetaKey = true
        let terminal = view.getTerminal()
        // OSC 9 carries both notifications (`9;text`) and ConEmu progress (`9;4;state;pct`).
        terminal.registerOscHandler(code: 9) { [weak self] data in
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.handleOsc9(text) }
        }
        terminal.registerOscHandler(code: 777) { [weak self] data in
            let parts = String(decoding: data, as: UTF8.self).split(separator: ";", maxSplits: 2).map(String.init)
            guard parts.first == "notify" else { return }
            Task { @MainActor in
                self?.tracker.noteNotification(title: parts.count > 1 ? parts[1] : "", body: parts.count > 2 ? parts[2] : "")
                self?.refreshInfo()
            }
        }
    }

    private func handleOsc9(_ text: String) {
        if text.hasPrefix("4;") {
            let fields = text.split(separator: ";").compactMap { Int($0) }
            // 4;0 clears, 4;1;N sets percent, 4;3 is indeterminate.
            if fields.count >= 2, fields[1] == 1, fields.count >= 3 { progress = Double(fields[2]) / 100 } else if fields.count >= 2, fields[1] == 0 { progress = nil }
        } else {
            tracker.noteNotification(title: "", body: text)
        }
        refreshInfo()
    }

    /// The command line this tile runs now: a fresh launch (with an assigned session id where the
    /// tool allows), or — after it has run once — the tool's resume form.
    private func commandToRun() -> String? {
        guard let command, !command.isEmpty else { return nil }
        if !hasStarted, sessionId == nil {
            let prepared = SessionResume.prepareLaunch(command)
            sessionId = prepared.sessionId
            return prepared.command
        }
        let id = sessionId
        if id == nil, !mayContinueLatest { return command }
        return SessionResume.resumeCommand(original: command, sessionId: id) ?? command
    }

    /// Shown on a shut-down tile: what Resume will run.
    public var resumeHint: String {
        guard let command, !command.isEmpty else { return "Resume opens a shell in \(cwd.abbreviatingHome)" }
        let next = sessionId != nil || mayContinueLatest
            ? SessionResume.resumeCommand(original: command, sessionId: sessionId) ?? command
            : command
        return "Resume runs: \(next)"
    }

    public func start() {
        tracker.restart()
        isSuspended = false
        launchedAt = Date()
        let run = commandToRun()
        hasStarted = true
        // Keep scanning through startup even if the program stays silent.
        lastOutputAt = Date()
        settledScanDone = false
        generation += 1
        let relay = ProcessRelay(session: self, generation: generation)
        self.relay = relay
        let process = LocalProcess(delegate: relay, dispatchQueue: .main)
        self.process = process
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = "-" + (shell as NSString).lastPathComponent
        var args: [String] = []
        if let run {
            // Run the tool, then fall back to an interactive shell so the tile stays useful.
            args = ["-l", "-i", "-c", "\(run); exec \(shell) -l -i"]
        }
        process.startProcess(executable: shell, args: args, environment: Self.environment(tileId: id),
                             execName: args.isEmpty ? shellName : nil, currentDirectory: cwd)
        isRunning = true
        refreshInfo()
    }

    /// Hangs up the whole session like closing a terminal window: interactive shells ignore
    /// SIGTERM, and the foreground program (an agent) is in its own process group.
    public func terminate() {
        guard isRunning, let process else { return }
        let pid = process.shellPid
        let foreground = process.childfd >= 0 ? tcgetpgrp(process.childfd) : -1
        if foreground > 0 { kill(-foreground, SIGHUP) }
        if pid > 0 {
            kill(-pid, SIGHUP)
            kill(pid, SIGHUP)
        }
        process.terminate()
        self.process = nil
        generation += 1
        isRunning = false
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            for _ in 0..<30 {
                if waitpid(pid, &status, WNOHANG) != 0 { return }
                usleep(100_000)
            }
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
    }

    /// Stop the process but keep the tile, its folder and its conversation id for Resume.
    public func shutDown() {
        if let dir = liveDirectory() { cwd = dir }
        terminate()
        isSuspended = true
        tracker.noteSuspended(resumeHint: resumeHint)
        refreshInfo()
    }

    /// Bring a shut-down tile back into the same conversation.
    public func resume() {
        view.getTerminal().resetToInitialState()
        start()
    }

    /// Restart keeps the conversation: it's a shut down and resume.
    public func restart() {
        terminate()
        resume()
    }

    /// Adopt the session a tool reported after launch (e.g. the Codex rollout this tile started).
    public func bind(sessionId: String) {
        guard self.sessionId == nil, SessionResume.isSafeId(sessionId) else { return }
        self.sessionId = sessionId
    }

    /// The shell's working directory right now (follows `cd`), read from the kernel.
    public func liveDirectory() -> String? {
        guard let pid = process?.shellPid, pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    public func send(_ bytes: [UInt8]) {
        guard isRunning, let process else { return }
        tracker.noteInput(at: Date())
        process.send(data: bytes[...])
    }

    public var terminal: Terminal { view.getTerminal() }

    public func setViewed(_ viewed: Bool) {
        tracker.isBeingViewed = viewed
        if viewed { tracker.acknowledge() }
        refreshInfo()
    }

    public func acknowledge() {
        tracker.acknowledge()
        refreshInfo()
    }

    public func rename(_ newTitle: String?) {
        customTitle = newTitle?.isEmpty == true ? nil : newTitle
        refreshInfo()
    }

    /// Called on the workspace display clock.
    func tick(now: Date) {
        if dirty {
            dirty = false
            revision &+= 1
        }
        // Timing-based transitions all happen within a few seconds of the last output; after
        // one scan of the settled screen there is nothing new to learn until more arrives.
        let quiet = now.timeIntervalSince(lastOutputAt)
        if quiet > 4 {
            if settledScanDone { return }
            settledScanDone = true
        }
        if tracker.tick(now: now, screenTail: terminal.screenTail(24)) { refreshInfo() }
    }

    private func refreshInfo() {
        var next = info
        next.title = customTitle ?? title
        next.activity = tracker.activity
        next.attention = tracker.attention
        next.detail = tracker.detail
        next.cols = terminal.cols
        next.rows = terminal.rows
        next.progress = progress
        next.subtitle = cwd.abbreviatingHome
        if next.activity == .working || next.activity != info.activity { next.lastActivityAt = Date() }
        if next != info { info = next }
    }

    static func environment(tileId: String) -> [String] {
        var env = ProcessInfo.processInfo.environment
        // Tessera may itself be launched from an agent; don't leak nesting markers into tiles.
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "TERM_SESSION_ID", "ITERM_SESSION_ID"] { env.removeValue(forKey: key) }
        for key in env.keys where key.hasPrefix("TESSERA_") { env.removeValue(forKey: key) }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Tessera"
        env["TESSERA_TILE_ID"] = tileId
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env.map { "\($0.key)=\($0.value)" }
    }
}

/// Forwards one process generation's callbacks, so a restarted tile never hears from its predecessor.
final class ProcessRelay: LocalProcessDelegate {
    weak var session: TerminalSession?
    let generation: Int

    init(session: TerminalSession, generation: Int) {
        self.session = session
        self.generation = generation
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        MainActor.assumeIsolated { session?.processEnded(generation: generation, status: exitCode) }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { session?.received(slice, generation: generation) }
    }

    func getWindowSize() -> winsize {
        MainActor.assumeIsolated { session?.windowSize ?? winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }
    }
}

extension TerminalSession {
    fileprivate func processEnded(generation: Int, status: Int32?) {
        guard generation == self.generation else { return }
        isRunning = false
        tracker.noteExit(code: status.map(Self.exitCode(fromWaitStatus:)))
        refreshInfo()
    }

    fileprivate func received(_ slice: ArraySlice<UInt8>, generation: Int) {
        guard generation == self.generation else { return }
        view.feed(byteArray: slice)
        lastOutputAt = Date()
        settledScanDone = false
        tracker.noteOutput(bytes: slice.count, at: lastOutputAt)
        dirty = true
        if !outputObservers.isEmpty {
            let bytes = Array(slice)
            for observer in outputObservers.values { observer(bytes) }
        }
    }

    fileprivate var windowSize: winsize {
        let t = view.getTerminal()
        return winsize(ws_row: UInt16(t.rows), ws_col: UInt16(t.cols), ws_xpixel: 0, ws_ypixel: 0)
    }

    /// LocalProcess reports the raw `waitpid` status; turn it into a shell-style exit code.
    nonisolated static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}

extension TerminalSession: TerminalViewDelegate {
    nonisolated public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated {
            guard isRunning, let process else { return }
            var size = winsize(ws_row: UInt16(newRows), ws_col: UInt16(newCols), ws_xpixel: 0, ws_ypixel: 0)
            _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
            dirty = true
            refreshInfo()
        }
    }

    nonisolated public func setTerminalTitle(source: TerminalView, title: String) {
        MainActor.assumeIsolated {
            let clean = title.trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty { self.title = clean }
            refreshInfo()
        }
    }

    nonisolated public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        MainActor.assumeIsolated {
            if let directory, let url = URL(string: directory), url.isFileURL { cwd = url.path } else if let directory { cwd = directory }
            refreshInfo()
        }
    }

    nonisolated public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { send(Array(data)) }
    }

    nonisolated public func scrolled(source: TerminalView, position: Double) {}

    nonisolated public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    nonisolated public func bell(source: TerminalView) {
        MainActor.assumeIsolated {
            tracker.noteBell(screenTail: terminal.screenTail(14), at: Date())
            refreshInfo()
        }
    }

    nonisolated public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
