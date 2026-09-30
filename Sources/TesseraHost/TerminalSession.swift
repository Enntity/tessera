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
    /// The agent (or launched) command this tile would bring back — what the user launched or typed,
    /// launcher and all, never rewritten with session flags. Nil when the tile is at a shell prompt.
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
    /// Secret the tile's shell hooks include in their reports, so printed output can't forge them.
    @ObservationIgnored private let shellNonce = ShellEvent.makeNonce()
    /// Extra environment applied last (tests point HOME somewhere harmless).
    @ObservationIgnored private let environmentOverrides: [String: String]
    /// The user's login shell (overridable for tests).
    @ObservationIgnored private let shell: String
    @ObservationIgnored private var hasStarted = false
    public private(set) var flavor: AgentFlavor
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
    /// Runs only while there is something to redraw or learn; a quiet terminal costs nothing.
    @ObservationIgnored private(set) var clock: Timer?
    @ObservationIgnored private var nextScanAt: Date = .distantPast
    @ObservationIgnored private var progress: Double?
    @ObservationIgnored public private(set) var isRunning = false
    /// Opens web links clicked in this terminal (the workspace makes them web tiles).
    @ObservationIgnored public var onOpenLink: ((URL) -> Void)?
    /// Called when what this tile would resume changes (an agent started or ended), so it can be saved.
    @ObservationIgnored public var onResumableChange: (() -> Void)?
    /// Raw output fan-out for remote clients.
    @ObservationIgnored public var outputObservers: [UUID: ([UInt8]) -> Void] = [:]

    static let defaultFont = NSFont(name: "SFMono-Regular", size: 12.5) ?? .monospacedSystemFont(ofSize: 12.5, weight: .regular)

    /// `label` names the tile until the program sets its own title (defaults to the command);
    /// `title` is a user-chosen name that always wins.
    public init(id: String = UUID().uuidString, command: String?, cwd: String, title: String? = nil, label: String? = nil,
                sessionId: String? = nil, resuming: Bool = false, mayContinueLatest: Bool = true, startSuspended: Bool = false,
                shell: String? = nil, environmentOverrides: [String: String] = [:],
                initialSize: CGSize = CGSize(width: 1180, height: 740)) {
        self.id = id
        self.command = command
        self.cwd = cwd
        self.sessionId = sessionId ?? command.flatMap(SessionResume.sessionId(in:))
        self.hasStarted = resuming
        self.shell = shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        self.environmentOverrides = environmentOverrides
        self.mayContinueLatest = mayContinueLatest
        let flavor = AgentFlavor.infer(fromCommand: command)
        self.flavor = flavor
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
        terminal.registerOscHandler(code: ShellEvent.oscCode) { [weak self] data in
            let payload = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard let self, let event = ShellEvent.parse(payload, nonce: self.shellNonce) else { return }
                self.handle(event)
            }
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

    /// What this tile runs now: the primary command (a fresh launch with an assigned id where the
    /// tool allows, or — after it has run once — the resume form) and a fresh-start fallback used if
    /// the primary fails quickly (deleted session, older CLI, launcher with its own session store).
    private func launchPlan() -> (primary: String, fallback: String?)? {
        guard let command, !command.isEmpty else { return nil }
        if !hasStarted, sessionId == nil {
            let prepared = SessionResume.prepareLaunch(command)
            sessionId = prepared.sessionId
            return (prepared.command, prepared.command == command ? nil : command)
        }
        let primary = resumeLine(for: command)
        let fresh = SessionResume.freshLaunch(original: command) ?? command
        return (primary, primary == fresh ? nil : fresh)
    }

    /// How `command` comes back into its conversation.
    private func resumeLine(for command: String) -> String {
        guard let id = sessionId else {
            // No known conversation: continue the latest only where that's been judged safe,
            // otherwise a clean fresh start (never the original `--last`/`--continue`).
            return mayContinueLatest
                ? SessionResume.resumeCommand(original: command, sessionId: nil) ?? command
                : SessionResume.freshLaunch(original: command) ?? command
        }
        // Claude only saves a conversation once a message is sent; an assigned id with no transcript
        // can't be resumed, so start it fresh under the same id.
        if SessionResume.tool(for: command) == .claude, !ClaudeSessions.transcriptExists(id, cwd: cwd),
           let fresh = SessionResume.freshLaunch(original: command, sessionId: id) {
            return fresh
        }
        return SessionResume.resumeCommand(original: command, sessionId: id) ?? command
    }

    /// Agent CLIs animate their titles with spinner glyphs (braille dots, ✳ ✶ ·); keep just the words.
    nonisolated static func cleanTitle(_ title: String) -> String {
        let spinner: (Unicode.Scalar) -> Bool = { s in
            (0x2800...0x28FF).contains(s.value) || (0x2700...0x27BF).contains(s.value) || "·•*∙⋅".unicodeScalars.contains(s)
        }
        let scalars = title.unicodeScalars.drop { spinner($0) || $0 == " " }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }

    /// Shown on a shut-down tile: what Resume will run.
    public var resumeHint: String {
        guard let command, !command.isEmpty else { return "Resume opens a shell in \(cwd.abbreviatingHome)" }
        return "Resume runs: \(resumeLine(for: command))"
    }

    public func start() {
        tracker.restart()
        isSuspended = false
        launchedAt = Date()
        let plan = launchPlan()
        hasStarted = true
        // Keep scanning through startup even if the program stays silent.
        lastOutputAt = Date()
        settledScanDone = false
        wake()
        generation += 1
        let relay = ProcessRelay(session: self, generation: generation)
        self.relay = relay
        let process = LocalProcess(delegate: relay, dispatchQueue: .main)
        self.process = process
        var args = ShellIntegration.interactiveArguments(shell, nonce: shellNonce)
        if let plan {
            // Run the tool (falling back to a fresh start if resuming fails fast), then an
            // interactive shell so the tile stays useful.
            args = ["-l", "-i", "-c", LaunchScript.build(primary: plan.primary, fallback: plan.fallback,
                                                         followUp: ShellIntegration.followUpShell(shell, nonce: shellNonce),
                                                         dialect: LaunchScript.dialect(forShell: shell), nonce: shellNonce)]
        }
        process.startProcess(executable: shell, args: args, environment: Self.environment(tileId: id, shell: shell, nonce: shellNonce, overrides: environmentOverrides),
                             execName: nil, currentDirectory: cwd)
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

    /// Redraws a changed screen (up to 10 fps) and re-reads its state four times a second.
    private func tick(now: Date) {
        if dirty {
            dirty = false
            revision &+= 1
        }
        // Timing-based transitions all happen within a few seconds of the last output; after
        // one scan of the settled screen there is nothing new to learn until more arrives.
        let quiet = now.timeIntervalSince(lastOutputAt)
        if quiet > 4, settledScanDone {
            clock?.invalidate()
            clock = nil
            return
        }
        guard now >= nextScanAt else { return }
        nextScanAt = now.addingTimeInterval(0.25)
        settledScanDone = quiet > 4
        if tracker.tick(now: now, screenTail: terminal.screenTail(24)) { refreshInfo() }
    }

    /// Starts the clock after anything that changes the screen, until it settles again.
    private func wake() {
        guard clock == nil else { return }
        let clock = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.tick(now: Date())
            }
        }
        clock.tolerance = 0.02
        // Common mode keeps tiles live while a menu is open or the window is being resized.
        RunLoop.main.add(clock, forMode: .common)
        self.clock = clock
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
        // While working, "last activity" follows along only every few seconds (ages read "now" under 5 s).
        if next.activity != info.activity || next.activity == .working && Date().timeIntervalSince(info.lastActivityAt) > 4 {
            next.lastActivityAt = Date()
        }
        if next != info { info = next }
    }

    /// The shell reported a typed command or a return to its prompt.
    private func handle(_ event: ShellEvent) {
        switch event {
        case .command(let typed, let expanded):
            // Only agent CLIs are worth bringing back; `ls` or `make` are not. Prefer the line as
            // typed; an alias is recognised through its expansion.
            guard let line = [typed, expanded].compactMap({ $0 }).first(where: { SessionResume.tool(for: $0) != nil }) else { return }
            command = line
            sessionId = SessionResume.sessionId(in: line)
            // A typed agent without a known id resumes only once its conversation is found;
            // "continue the latest" could land in someone else's.
            mayContinueLatest = false
            hasStarted = true
            launchedAt = Date()
            flavor = AgentFlavor.infer(fromCommand: line)
            if let dir = liveDirectory() { cwd = dir }
            info.flavor = flavor
            refreshInfo()
            onResumableChange?()
        case .startedFresh:
            // The resume failed and the fallback started a new conversation: find that one instead.
            sessionId = nil
            mayContinueLatest = false
            launchedAt = Date()
            onResumableChange?()
        case .prompt:
            guard command != nil else { return }
            command = nil
            sessionId = nil
            flavor = .shell
            info.flavor = .shell
            refreshInfo()
            onResumableChange?()
        }
    }

    static func environment(tileId: String, shell: String, nonce: String, overrides: [String: String] = [:]) -> [String] {
        var env = ProcessInfo.processInfo.environment
        // Tessera may itself be launched from an agent; don't leak nesting markers into tiles.
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "TERM_SESSION_ID", "ITERM_SESSION_ID"] { env.removeValue(forKey: key) }
        for key in env.keys where key.hasPrefix("TESSERA_") { env.removeValue(forKey: key) }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Tessera"
        env["TESSERA_TILE_ID"] = tileId
        env.merge(ShellIntegration.environment(shell: shell, base: ProcessInfo.processInfo.environment, nonce: nonce)) { _, new in new }
        env.merge(overrides) { _, new in new }
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
        wake()
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
            wake()
            refreshInfo()
        }
    }

    nonisolated public func setTerminalTitle(source: TerminalView, title: String) {
        MainActor.assumeIsolated {
            // Agents animate their titles several times a second; only a new title is news.
            let clean = Self.cleanTitle(title)
            guard !clean.isEmpty, clean != self.title else { return }
            self.title = clean
            refreshInfo()
        }
    }

    nonisolated public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        MainActor.assumeIsolated {
            // Shells report this at every prompt.
            guard let directory else { return }
            let dir = URL(string: directory).flatMap { $0.isFileURL ? $0.path : nil } ?? directory
            guard dir != cwd else { return }
            cwd = dir
            refreshInfo()
        }
    }

    nonisolated public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { send(Array(data)) }
    }

    nonisolated public func scrolled(source: TerminalView, position: Double) {}

    nonisolated public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        MainActor.assumeIsolated {
            if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let open = onOpenLink {
                open(url)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    nonisolated public func bell(source: TerminalView) {
        MainActor.assumeIsolated {
            tracker.noteBell(screenTail: terminal.screenTail(14), at: Date())
            refreshInfo()
        }
    }

    nonisolated public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
