import AppKit
import Foundation
import Observation
import TesseraKit

/// The board: every tile, its order, what is open, and what needs the user.
@Observable
@MainActor
public final class Workspace {
    /// What the board shows: everything, what needs the user, or one of the user's tabs.
    public enum Filter: Hashable, Sendable {
        case all, attention, group(String)
    }

    public private(set) var order: [String] = []
    public private(set) var terminals: [String: TerminalSession] = [:]
    public private(set) var browsers: [String: BrowserSession] = [:]
    public let agents = AgentAppWatcher()
    /// The DeepSeek Harness web server used to open dsh sessions.
    public let dsh = DshWebServer()
    public let usage: UsageService
    public let machines: MachineMonitor
    public private(set) var presets: [LaunchPreset] = LaunchCatalog.known
    /// Desktop agent apps on this Mac that can start conversations from Tessera.
    public let installedApps: [AgentApp] = AgentApp.allCases.filter {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
    }

    public var selectedId: String?
    public private(set) var expandedId: String?
    public var filter: Filter = .all
    public private(set) var groups = TileGroups()
    /// Snap the Claude / Codex window onto the tile when an app session is opened.
    public var placeNativeWindows = true
    /// Bring terminals back into their conversations when Tessera opens (else they wait, shut down).
    public var resumeOnLaunch = true
    public var defaultDirectory: String = NSHomeDirectory()

    /// Emits whenever tile membership, order, or any tile's metadata changes (for remote clients).
    @ObservationIgnored public var onTilesChanged: (() -> Void)?

    @ObservationIgnored private var agentAcknowledged: [String: Date] = [:]
    @ObservationIgnored private var hiddenAgents: [String: Date] = [:]
    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var lastPublished: [TileInfo] = []
    @ObservationIgnored private var firstAgentScan = true
    @ObservationIgnored private let directory: URL

    public init() {
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tessera")
        #if DEBUG
        // Lets a development instance run beside the real one without sharing its board.
        if let override = ProcessInfo.processInfo.environment["TESSERA_DATA_DIR"] { dir = URL(fileURLWithPath: override) }
        #endif
        directory = dir
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        usage = UsageService(directory: directory)
        machines = MachineMonitor(directory: directory)
    }

    public func start() {
        restore()
        agents.start()
        usage.start()
        machines.start()
        DispatchQueue.global(qos: .utility).async {
            let found = LaunchCatalog.detectInstalled()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.presets = found } }
        }
        // Common mode keeps tiles live while a menu is open or the window is being resized.
        let clock = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(clock, forMode: .common)
        self.clock = clock
        if order.isEmpty { launch(command: nil) }
    }

    // MARK: Tiles

    public func info(_ id: String) -> TileInfo? {
        if let t = terminals[id] { return t.info }
        if let b = browsers[id] { return b.info }
        if let a = agents.sessions[id] { return agentInfo(a) }
        return nil
    }

    public var allTiles: [TileInfo] { order.compactMap(info) }

    public var visibleTiles: [TileInfo] {
        let members: Set<String>? = if case .group(let g) = filter { groups.members(of: g) } else { nil }
        return allTiles.filter { tile in
            switch filter {
            case .all: true
            case .attention: tile.attention || tile.activity == .needsInput || tile.id == expandedId
            case .group: members?.contains(tile.id) == true || tile.id == expandedId
            }
        }
    }

    public var counts: (working: Int, needsInput: Int, done: Int) {
        let tiles = allTiles
        return (tiles.filter { $0.activity == .working }.count,
                tiles.filter { $0.activity == .needsInput }.count,
                tiles.filter { $0.attention && $0.activity != .needsInput }.count)
    }

    @discardableResult
    public func launch(command: String?, cwd: String? = nil, title: String? = nil) -> String {
        let session = TerminalSession(command: command, cwd: cwd ?? defaultDirectory, title: title)
        adopt(session)
        insert(session.id)
        return session.id
    }

    @discardableResult
    public func openBrowser(_ raw: String) -> String? {
        guard let url = Self.normalizeURL(raw) else { return nil }
        let session = BrowserSession(url: url)
        browsers[session.id] = session
        insert(session.id)
        return session.id
    }

    // MARK: Tabs

    @discardableResult
    public func createGroup(named name: String, with tileId: String? = nil) -> String {
        let id = groups.create(named: name)
        if let tileId { groups.assign(tileId, to: id) }
        filter = .group(id)
        save()
        return id
    }

    public func renameGroup(_ id: String, to name: String) {
        groups.rename(id, to: name)
        save()
    }

    public func deleteGroup(_ id: String) {
        groups.delete(id)
        if filter == .group(id) { filter = .all }
        save()
    }

    /// Moves a tile into a tab, or back to All only when `groupId` is nil.
    public func move(tile tileId: String, toGroup groupId: String?) {
        guard info(tileId) != nil else { return }  // e.g. an account row dropped on a tab
        groups.assign(tileId, to: groupId)
        save()
    }

    /// Tiles in a tab, for its count and attention dot.
    public func tiles(inGroup id: String) -> [TileInfo] {
        let members = groups.members(of: id)
        return allTiles.filter { members.contains($0.id) }
    }

    private func insert(_ id: String) {
        // Viewing a tab? New work belongs there.
        if case .group(let g) = filter { groups.assign(id, to: g) }
        // New tiles land after the selection so related work clusters.
        if let sel = selectedId, let i = order.firstIndex(of: sel) {
            order.insert(id, at: i + 1)
        } else {
            order.append(id)
        }
        selectedId = id
        save()
    }

    public func close(_ id: String) {
        if expandedId == id { collapse() }
        if let t = terminals.removeValue(forKey: id) { t.terminate() }
        if let b = browsers.removeValue(forKey: id) { b.webView.stopLoading() }
        if agents.sessions[id] != nil { hiddenAgents[id] = Date() } else { groups.assign(id, to: nil) }
        if let i = order.firstIndex(of: id) {
            order.remove(at: i)
            if selectedId == id { selectedId = order.indices.contains(i) ? order[i] : order.last }
        }
        save()
    }

    public func move(_ id: String, before target: String) {
        guard id != target, let from = order.firstIndex(of: id) else { return }
        order.remove(at: from)
        let to = order.firstIndex(of: target) ?? order.endIndex
        order.insert(id, at: to)
        save()
    }

    /// Stop a terminal but keep its tile and conversation for later.
    public func shutDown(_ id: String) {
        terminals[id]?.shutDown()
        save()
    }

    public func resume(_ id: String) {
        terminals[id]?.resume()
        save()
    }

    public func shutDownAll() {
        for t in terminals.values where !t.isSuspended { t.shutDown() }
        save()
    }

    public func resumeAll() {
        for id in order { if let t = terminals[id], t.isSuspended { t.resume() } }
        save()
    }

    /// On quit: record every terminal's folder and conversation, then stop them cleanly.
    public func prepareForQuit() {
        save()
        dsh.stop()
        for t in terminals.values { t.terminate() }
    }

    public func restart(_ id: String) {
        terminals[id]?.restart()
        browsers[id]?.webView.reload()
    }

    public func rename(_ id: String, to title: String) {
        terminals[id]?.rename(title)
        save()
    }

    // MARK: Focus

    public func expand(_ id: String) {
        if let prev = expandedId, prev != id { setViewed(prev, false) }
        expandedId = id
        selectedId = id
        setViewed(id, true)
    }

    public func collapse() {
        if let id = expandedId { setViewed(id, false) }
        expandedId = nil
    }

    public func acknowledge(_ id: String) {
        terminals[id]?.acknowledge()
        browsers[id]?.acknowledge()
        if agents.sessions[id] != nil { agentAcknowledged[id] = Date() }
    }

    private func setViewed(_ id: String, _ viewed: Bool) {
        terminals[id]?.setViewed(viewed)
        browsers[id]?.setViewed(viewed)
        if agents.sessions[id] != nil { agentAcknowledged[id] = Date() }
    }

    /// Jump to the next tile that is waiting on the user, oldest first.
    public func nextAttention() -> String? {
        let waiting = allTiles.filter { $0.attention || $0.activity == .needsInput }
        guard !waiting.isEmpty else { return nil }
        let sorted = waiting.sorted { $0.lastActivityAt < $1.lastActivityAt }
        if let current = expandedId, let i = sorted.firstIndex(where: { $0.id == current }) {
            return sorted[(i + 1) % sorted.count].id
        }
        return sorted.first?.id
    }

    /// Open a desktop-app conversation in its own app, snapped to `rect` (AppKit screen coordinates).
    public func openNative(_ id: String, at rect: CGRect?) {
        guard let a = agents.sessions[id] else { return }
        agentAcknowledged[id] = Date()
        if a.flavor == .dsh { return openDsh(a) }
        WindowPlacer.open(a.openURL, bundleID: a.bundleID, placeAt: placeNativeWindows ? rect : nil)
    }

    // MARK: New app conversations

    /// A conversation just started in a desktop app: when its tile appears, open it in place.
    @ObservationIgnored private var pendingAppConversation: (app: AgentApp, since: Date)?

    /// Starts a new conversation in the Claude or Codex app (in `folder`, with `prompt` placed in its
    /// composer), snapping the app window onto `rect` (AppKit screen coordinates) when allowed.
    public func newAppConversation(_ app: AgentApp, folder: String?, prompt: String? = nil, placeAt rect: CGRect? = nil) {
        guard let url = app.newConversationURL(folder: folder, prompt: prompt) else { return }
        pendingAppConversation = (app, Date())
        WindowPlacer.open(url, bundleID: app.bundleID, placeAt: placeNativeWindows ? rect : nil)
    }

    /// The new conversation's tile shows up once the app saves it (after the first message).
    private func openPendingAppConversation(newlyAdded: [AgentAppSession]) {
        guard let pending = pendingAppConversation else { return }
        if Date().timeIntervalSince(pending.since) > 900 { pendingAppConversation = nil; return }
        guard let match = newlyAdded.first(where: { $0.flavor == pending.app.flavor && $0.lastActivityAt >= pending.since.addingTimeInterval(-5) })
        else { return }
        pendingAppConversation = nil
        agentAcknowledged[match.id] = Date()
        expand(match.id)
    }

    // MARK: DeepSeek Harness

    /// The dsh web UI, shown inside whichever dsh session's panel is open. It's one shared page,
    /// never a tile of its own, so a session never appears twice on the board.
    public private(set) var dshPage: BrowserSession?

    /// Brings up dsh web (starting Tessera's server if needed; the first load uses the token URL,
    /// which signs the page in) and selects this session in it.
    private func openDsh(_ session: AgentAppSession) {
        dsh.ensureRunning { [weak self] result in
            guard let self, case .success(let launch) = result else { return }
            let page: BrowserSession
            if let existing = self.dshPage, existing.url?.port == self.dsh.baseURL?.port {
                page = existing
            } else {
                page = BrowserSession(url: launch)
                self.dshPage = page
            }
            page.evaluateWhenLoaded(Self.selectDshSessionScript(title: session.title,
                                                                folder: (session.cwd as NSString).lastPathComponent))
        }
    }

    /// dsh web has no per-session URL, so select the session in its sidebar. Sessions are grouped
    /// under workspace rows that don't render their sessions while collapsed, and long lists hide
    /// rows behind "Show N more sessions" — so: wait for the tree, expand the session's workspace
    /// (by folder name, else every collapsed one), reveal overflow until the title appears, click it.
    nonisolated static func selectDshSessionScript(title: String, folder: String) -> String {
        func js(_ s: String) -> String {
            (try? JSONSerialization.data(withJSONObject: [s])).map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        }
        return """
        (async function(title, folder){
          const sleep = ms => new Promise(r => setTimeout(r, ms));
          const rows = () => Array.from(document.querySelectorAll('[role="treeitem"]'));
          const text = r => ((r.querySelector('[class*="title"]') || r).textContent || '').trim();
          const sessionRow = () => rows().find(r => /sessionRow/.test(r.className) && text(r) === title);
          for (let i = 0; i < 40 && !rows().length; i++) await sleep(250);
          let row = sessionRow();
          if (!row) {
            const projects = rows().filter(r => /projectRow/.test(r.className));
            const own = projects.filter(p => text(p) === folder);
            for (const p of (own.length ? own : projects)) {
              if (p.getAttribute('aria-expanded') === 'false') { p.click(); await sleep(300); }
            }
            row = sessionRow();
          }
          for (let i = 0; !row && i < 25; i++) {
            const more = Array.from(document.querySelectorAll('button')).filter(b => /more sessions/i.test(b.textContent || ''));
            if (!more.length) break;
            more.forEach(b => b.click());
            await sleep(350);
            row = sessionRow();
          }
          if (row && !/selected/.test(row.className)) { row.scrollIntoView({block: 'center'}); row.click(); }
        })(\(js(title))[0], \(js(folder))[0]);
        """
    }

    // MARK: Agent sessions

    private func agentInfo(_ a: AgentAppSession) -> TileInfo {
        let ack = agentAcknowledged[a.id] ?? .distantPast
        let last = a.snapshot.lastEventAt ?? a.lastActivityAt
        var detail = a.snapshot.detail
        if detail == nil, a.snapshot.activity != .working { detail = a.summary }
        let unseen = a.snapshot.activity.isAttention && last > ack && expandedId != a.id
        // Finished work the user has already seen is just idle, same as a terminal.
        let activity: TileActivity = a.snapshot.activity == .done && !unseen ? .idle : a.snapshot.activity
        return TileInfo(id: a.id, kind: .agentSession, flavor: a.flavor, title: a.title,
                        subtitle: a.cwd.abbreviatingHome, activity: activity,
                        attention: unseen,
                        lastActivityAt: a.lastActivityAt, detail: detail)
    }

    private func syncAgents() {
        let live = agents.sessions
        if firstAgentScan, !live.isEmpty {
            // Whatever finished before Tessera opened has been seen elsewhere; don't light it up.
            firstAgentScan = false
            let now = Date()
            for id in live.keys { agentAcknowledged[id] = now }
        }
        let newest = live.values.sorted { $0.lastActivityAt > $1.lastActivityAt }
        var added: [AgentAppSession] = []
        for a in newest where !order.contains(a.id) {
            if let hidden = hiddenAgents[a.id], a.lastActivityAt <= hidden { continue }
            hiddenAgents[a.id] = nil
            if agentAcknowledged[a.id] == nil { agentAcknowledged[a.id] = .distantPast }
            order.append(a.id)
            added.append(a)
        }
        openPendingAppConversation(newlyAdded: added)
        let before = order.count
        order.removeAll { id in id.contains(":") && live[id] == nil && terminals[id] == nil && browsers[id] == nil }
        if order.count != before, let e = expandedId, !order.contains(e) { expandedId = nil }
    }

    // MARK: Clock

    private var tickCount = 0

    private func tick() {
        tickCount &+= 1
        let now = Date()
        for t in terminals.values { t.tick(now: now) }
        if tickCount % 50 == 0 { bindAgentSessions(now: now) }
        if tickCount % 5 == 0 {
            syncAgents()
            if usage.codexRateLimits != agents.codexRateLimits { usage.codexRateLimits = agents.codexRateLimits }
            let tiles = allTiles
            if tiles != lastPublished {
                lastPublished = tiles
                onTilesChanged?()
            }
        }
    }

    private func adopt(_ session: TerminalSession) {
        session.onResumableChange = { [weak self] in self?.save() }
        // A link clicked in a terminal (e.g. the URL a dev server or `dsh web` prints) opens as a
        // web tile right after that terminal, and comes forward.
        session.onOpenLink = { [weak self, weak session] url in
            guard let self, let session else { return }
            self.selectedId = session.id
            if let id = self.openBrowser(url.absoluteString) { self.expand(id) }
        }
        terminals[session.id] = session
    }

    // MARK: Session binding

    @ObservationIgnored private var binding = false

    /// Agents whose conversation id isn't known yet (Codex, or anything typed into a shell or started
    /// through a launcher) are matched to the session file their tool writes.
    private func bindAgentSessions(now: Date) {
        guard !binding else { return }
        // Keep looking for as long as the agent runs: a conversation may start long after launch.
        let waiting = terminals.values.filter { $0.isRunning && !$0.isSuspended && $0.sessionId == nil }
        func candidates(_ tool: SessionResume.Tool) -> [CodexRollouts.Candidate] {
            let all = waiting.filter { $0.command.flatMap(SessionResume.tool(for:)) == tool }
                .map { CodexRollouts.Candidate(tileId: $0.id, cwd: $0.cwd, launchedAt: $0.launchedAt,
                                               continuing: $0.command.map(SessionResume.continuesLatest) ?? false) }
            // Two unbound agents started in the same folder within a minute can't be told apart by
            // folder and time; binding the wrong one would resume someone else's conversation, so
            // leave both unbound (they resume fresh) rather than guess.
            return all.filter { c in
                !all.contains { $0.tileId != c.tileId && $0.cwd == c.cwd && abs($0.launchedAt.timeIntervalSince(c.launchedAt)) < 60 }
            }
        }
        let codex = candidates(.codex), claude = candidates(.claude)
        guard !codex.isEmpty || !claude.isEmpty else { return }
        let claimed = Set(terminals.values.compactMap(\.sessionId))
        binding = true
        DispatchQueue.global(qos: .utility).async {
            var found = codex.isEmpty ? [:] : CodexRollouts.bind(codex, claimed: claimed)
            if !claude.isEmpty { found.merge(ClaudeSessions.bind(claude, claimed: claimed.union(found.values))) { a, _ in a } }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.binding = false
                    for (tile, session) in found { self.terminals[tile]?.bind(sessionId: session) }
                    if !found.isEmpty { self.save() }
                }
            }
        }
    }

    // MARK: Persistence

    struct Saved: Codable {
        struct Tile: Codable {
            var id: String
            var kind: TileKind
            var command: String?
            var cwd: String?
            var title: String?
            var url: String?
            var sessionId: String?
            var suspended: Bool?
        }
        var tiles: [Tile]
        var defaultDirectory: String?
        var placeNativeWindows: Bool?
        var groups: [TileGroup]?
        var resumeOnLaunch: Bool?
    }

    private var saveURL: URL { directory.appendingPathComponent("workspace.json") }

    public func save() {
        var savedIds: Set<String> = []
        let tiles: [Saved.Tile] = order.compactMap { id in
            if let t = terminals[id] {
                // Never record one conversation for two tiles; the later one will start fresh.
                let session = t.sessionId.flatMap { savedIds.insert($0).inserted ? $0 : nil }
                return .init(id: id, kind: .terminal, command: t.command, cwd: t.liveDirectory() ?? t.cwd, title: t.customTitle,
                             sessionId: session, suspended: t.isSuspended)
            }
            if let b = browsers[id] { return .init(id: id, kind: .browser, url: b.url?.absoluteString) }
            return nil
        }
        let saved = Saved(tiles: tiles, defaultDirectory: defaultDirectory, placeNativeWindows: placeNativeWindows,
                          groups: groups.list, resumeOnLaunch: resumeOnLaunch)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: saveURL, options: .atomic) }
    }

    private func restore() {
        guard let data = try? Data(contentsOf: saveURL), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        defaultDirectory = saved.defaultDirectory ?? defaultDirectory
        placeNativeWindows = saved.placeNativeWindows ?? true
        groups = TileGroups(saved.groups ?? [])
        resumeOnLaunch = saved.resumeOnLaunch ?? true
        // One tile per conversation; "continue latest" only where it can't collide (see RestorePlan).
        let plan = RestorePlan.plan(saved.tiles.filter { $0.kind == .terminal }.map { tile in
            RestorePlan.Tile(id: tile.id, command: tile.command, cwd: tile.cwd ?? defaultDirectory, sessionId: tile.sessionId)
        })
        for tile in saved.tiles {
            switch tile.kind {
            case .terminal:
                let cwd = tile.cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? defaultDirectory
                let decision = plan[tile.id] ?? RestorePlan.Decision(sessionId: nil, mayContinueLatest: false)
                let s = TerminalSession(id: tile.id, command: tile.command, cwd: cwd, title: tile.title, label: tile.command,
                                        sessionId: decision.sessionId, resuming: true, mayContinueLatest: decision.mayContinueLatest,
                                        startSuspended: tile.suspended == true || !resumeOnLaunch)
                adopt(s)
                order.append(s.id)
            case .browser:
                if let raw = tile.url, let url = URL(string: raw) {
                    let b = BrowserSession(id: tile.id, url: url)
                    browsers[b.id] = b
                    order.append(b.id)
                }
            case .agentSession:
                break
            }
        }
        selectedId = order.first
    }

    static func normalizeURL(_ raw: String) -> URL? { WebAddress.normalize(raw) }
}
