import Foundation
import TesseraKit

/// The overseer's conversation, watched for the panel: the transcript of the agent in the
/// overseer's tile, read a little at a time like `AgentAppWatcher` reads the rest of the board.
/// While the panel is open it is read every second; otherwise every five. Only a Claude overseer
/// has a transcript (a Codex rollout can't be found by session id), so `hasTranscript` is what
/// the panel's chat view hangs on, not whether the file is there yet — an agent writes it with
/// its first answer.
@Observable
@MainActor
public final class OverseerChat {
    /// What the transcript says now; nil while there is none (a non-Claude agent, no bound
    /// session, or nothing written yet).
    public private(set) var snapshot: ConversationSnapshot?
    /// The overseer's agent can have a transcript. A fresh Claude has none on disk until its
    /// first reply, so this is the agent, not the file.
    public private(set) var hasTranscript = false
    /// The last thing the overseer said: the last assistant item with text in it.
    public private(set) var latestReply: ConversationItem?
    /// `latestReply` is one the user hasn't had the panel open to. Cleared by `markSeen`.
    public private(set) var unread = false
    /// Set while the panel shows the conversation: polling goes to every second.
    public var watching = false {
        didSet {
            guard watching != oldValue, timer != nil else { return }
            arm()
        }
    }

    /// The last reply the user saw (persisted so a restart doesn't mark it new again).
    @ObservationIgnored private var seenId = Preferences.store.string(forKey: "tessera.overseerSeenReply")
    /// The projects folder transcripts are found in (a test seam; normally Claude's own).
    @ObservationIgnored private let projects: URL
    @ObservationIgnored private weak var workspace: Workspace?
    @ObservationIgnored private var timer: Timer?
    /// The tail's state, only touched on the read thread (and by `pollNow` in tests).
    @ObservationIgnored private let reader = Reader()
    @ObservationIgnored private var reading = false

    private final class Reader: @unchecked Sendable {
        var tail = TranscriptTail(parser: .claude(ClaudeTranscriptParser()))
        var path: String?

        /// Advances the tail on `path` (reset when the transcript changes) and takes its snapshot.
        func read(path: String?) -> ConversationSnapshot? {
            guard let path else { return nil }
            if self.path != path {
                self.path = path
                tail = TranscriptTail(parser: .claude(ClaudeTranscriptParser()))
            }
            guard tail.advance(path: path), case .claude(let parser) = tail.parser else { return nil }
            return parser.snapshot(now: Date())
        }
    }

    public init(projects: URL? = nil) {
        self.projects = projects ?? ClaudeSessions.projects
    }

    /// What the poll reads for the overseer's tile: its agent command and bound session.
    struct Source {
        var command: String?
        var sessionId: String?
        var directory: URL
    }

    /// The overseer's transcript, when its agent keeps one. Only Claude's layout is known (a
    /// Codex rollout is found by rollout id, not the bound session id), so anything else is
    /// terminal-only in the panel.
    static func transcriptPath(source: Source, projects: URL? = nil) -> String? {
        let projects = projects ?? ClaudeSessions.projects
        guard let id = source.sessionId, let command = source.command,
              SessionResume.tool(for: command) == .claude, SessionResume.isSafeId(id) else { return nil }
        let folder = ClaudeSessions.projectFolder(for: source.directory.path)
        return projects.appendingPathComponent(folder).appendingPathComponent(id + ".jsonl").path
    }

    func attach(_ workspace: Workspace) { self.workspace = workspace }

    /// Called with the workspace: polls at `watching`'s pace from then on.
    public func start() {
        arm()
        refresh()
    }

    private func arm() {
        timer?.invalidate()
        let interval: TimeInterval = watching ? 1 : 5
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = watching ? 0.2 : 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// The overseer's own state, read from its tile; the read itself happens off the main thread.
    private func refresh() {
        var source: Source?
        if let workspace, let id = workspace.overseerId, let terminal = workspace.terminals[id] {
            source = Source(command: terminal.command, sessionId: terminal.sessionId, directory: workspace.overseerDirectory)
        }
        poll(source)
    }

    /// One poll for `source`: the read runs in the background; the publish happens here if it
    /// differs from the last (the same contract as `AgentAppWatcher`).
    func poll(_ source: Source?) {
        let transcript = source.flatMap { Self.transcriptPath(source: $0, projects: projects) }
        if hasTranscript != (transcript != nil) { hasTranscript = transcript != nil }
        guard !reading else { return }
        reading = true
        DispatchQueue.global(qos: .utility).async { [self] in
            let snapshot = reader.read(path: transcript)
            DispatchQueue.main.async { MainActor.assumeIsolated { [self] in
                self.reading = false
                self.publish(snapshot)
            } }
        }
    }

    /// Synchronous poll, for tests: what `poll` does in the background, inline.
    func pollNow(_ source: Source?) {
        let transcript = source.flatMap { Self.transcriptPath(source: $0, projects: projects) }
        if hasTranscript != (transcript != nil) { hasTranscript = transcript != nil }
        publish(reader.read(path: transcript))
    }

    private func publish(_ snapshot: ConversationSnapshot?) {
        if self.snapshot != snapshot { self.snapshot = snapshot }
        let reply = snapshot?.items.last { $0.role == .assistant && !$0.text.isEmpty }
        if latestReply != reply { latestReply = reply }
        // A reply that lands while the panel is open is being looked at: it isn't new.
        if watching, let id = latestReply?.id, id != seenId {
            seenId = id
            Preferences.store.set(id, forKey: "tessera.overseerSeenReply")
        }
        let now = latestReply?.id != nil && latestReply?.id != seenId
        if unread != now { unread = now }
    }

    /// The panel was opened (or its latest reply already was): this one isn't new anymore.
    public func markSeen() {
        seenId = latestReply?.id ?? seenId
        Preferences.store.set(seenId, forKey: "tessera.overseerSeenReply")
        if unread { unread = false }
    }
}
