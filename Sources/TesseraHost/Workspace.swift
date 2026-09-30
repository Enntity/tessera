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

    /// Always a tile the board shows, or nil on an empty board (see `reconcileSelection`).
    public private(set) var selectedId: String?
    public private(set) var expandedId: String?
    public var filter: Filter = .all { didSet { reconcileSelection() } }
    public private(set) var groups = TileGroups()
    /// Place the Claude / Codex window where the opened tile would sit when an app session is opened.
    public var placeNativeWindows = true
    /// Bring terminals back into their conversations when Tessera opens (else they wait, shut down).
    public var resumeOnLaunch = true
    public var defaultDirectory: String = NSHomeDirectory()
    /// Another Tessera already runs this board (its pid, 0 if unknown): this copy must not start.
    public let boardHolder: pid_t?
    /// Kept current as tiles change (see `BoardState`).
    public private(set) var state = BoardState()

    /// A link clicked in a terminal (e.g. the URL a dev server or `dsh web` prints): the app opens
    /// it as a web tile.
    @ObservationIgnored public var onLink: ((URL) -> Void)?

    /// Observed: acknowledging an agent session changes how its tile looks.
    private var agentAcknowledged: [String: Date] = [:]
    /// Names the user gave app sessions (terminals and pages carry their own).
    private var agentTitles: [String: String] = [:]
    @ObservationIgnored private var hiddenAgents: [String: Date] = [:]
    /// The order last saved, app sessions included: they take their places again as they reappear.
    @ObservationIgnored private var savedOrder: [String] = []
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
        boardHolder = BoardLock.take(in: directory)
        usage = UsageService(directory: directory)
        machines = MachineMonitor(directory: directory)
    }

    public func start() {
        restore()
        observe({ [weak self] in BoardState(self?.allTiles ?? []) }) { [weak self] state in
            guard let self, self.state != state else { return }
            self.state = state
            // Needs you shows only what waits: a tile that stops waiting takes the selection off with it.
            if filter == .attention { reconcileSelection() }
        }
        agents.onChange = { [weak self] in self?.agentsChanged() }
        agents.start()
        usage.start()
        machines.start()
        DispatchQueue.global(qos: .utility).async {
            let found = LaunchCatalog.detectInstalled()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.presets = found } }
        }
        let binder = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.bindAgentSessions() }
        }
        binder.tolerance = 1
        RunLoop.main.add(binder, forMode: .common)
        if order.isEmpty { launch(command: nil) }
    }

    // MARK: Tiles

    public func info(_ id: String) -> TileInfo? {
        if let t = terminals[id] { return t.info }
        if let b = browsers[id] { return b.info }
        if let a = agents.session(id) { return agentInfo(a) }
        return nil
    }

    /// Whether `id` is on the board (a closed app session is still known, but not on it). Unlike
    /// `info`, this doesn't read (or observe) the tile's data.
    public func exists(_ id: String) -> Bool { order.contains(id) }

    public var allTiles: [TileInfo] { order.compactMap(info) }

    /// The tiles the board shows, in order. Reads membership and `state`, not every tile's data.
    public var visibleIds: [String] {
        switch filter {
        case .all: return order
        case .attention: return order.filter { state.needsUser.contains($0) || $0 == expandedId }
        case .group(let g):
            let members = groups.members(of: g)
            return order.filter { members.contains($0) || $0 == expandedId }
        }
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
        guard let url = WebAddress.normalize(raw) else { return nil }
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
        reconcileSelection()
        save()
    }

    /// New work belongs in the tab being viewed. From Needs you, where it wouldn't show, the view
    /// goes to All.
    private func tabForNewTiles() -> String? {
        if filter == .attention { filter = .all }
        if case .group(let g) = filter { return g }
        return nil
    }

    private func insert(_ id: String) {
        groups.assign(id, to: tabForNewTiles())
        // New tiles land after the selection so related work clusters.
        if let sel = selectedId, let i = order.firstIndex(of: sel) {
            order.insert(id, at: i + 1)
        } else {
            order.append(id)
        }
        selectedId = id
        save()
    }

    /// Closes a terminal or page for good; an app conversation is only hidden until it is active again.
    public func close(_ id: String) {
        guard exists(id) else { return }
        if expandedId == id { collapse() }
        let visible = visibleIds
        if let t = terminals.removeValue(forKey: id) { t.terminate() }
        if let b = browsers.removeValue(forKey: id) { b.webView.stopLoading() }
        if agents.sessions[id] != nil { hiddenAgents[id] = Date() } else { groups.assign(id, to: nil) }
        order.removeAll { $0 == id }
        if selectedId == id { selectedId = Self.neighbor(of: id, in: visible) }
        save()
    }

    /// What is selected once `id` leaves the tiles on show: the one that takes its place, else the
    /// one before it.
    nonisolated static func neighbor(of id: String, in visible: [String]) -> String? {
        guard let i = visible.firstIndex(of: id) else { return visible.first }
        return i + 1 < visible.count ? visible[i + 1] : i > 0 ? visible[i - 1] : nil
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

    public func isSuspended(_ id: String) -> Bool { terminals[id]?.isSuspended == true }

    /// Gives any tile a name of the user's own; an empty one goes back to the tile's own title.
    public func rename(_ id: String, to title: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        terminals[id]?.rename(name)
        browsers[id]?.rename(name)
        if agents.sessions[id] != nil { agentTitles[id] = name.isEmpty ? nil : name }
        save()
    }

    // MARK: Selection and the open tile

    /// Selects a tile, going to All when the tab or filter being viewed hides it.
    public func select(_ id: String) {
        guard exists(id) else { return }
        if !visibleIds.contains(id) { filter = .all }
        selectedId = id
    }

    /// Keeps the selection on a tile the board shows: when it isn't (a tab change, a tile closed or
    /// filed elsewhere), it goes to the first one.
    private func reconcileSelection() {
        let visible = visibleIds
        guard selectedId.map(visible.contains) != true, selectedId != visible.first else { return }
        selectedId = visible.first
    }

    /// Opens a tile: zoomed open on the board, or, for a Claude or Codex conversation whose app is
    /// installed, straight in that app, placed at `rect` (AppKit screen coordinates). `inApp: false`
    /// keeps such a conversation in Tessera, as its transcript. An id not on the board opens nothing.
    public func open(_ id: String, inApp: Bool = true, nativeAt rect: CGRect? = nil) {
        guard exists(id) else { return }
        if app(opening: id, inApp: inApp) != nil {
            collapse()
            select(id)
            openNative(id, at: rect)
        } else {
            if let prev = expandedId, prev != id { setViewed(prev, false) }
            select(id)
            expandedId = id
            setViewed(id, true)
        }
    }

    /// Back to the board; the tile stays selected.
    public func collapse() {
        guard let id = expandedId else { return }
        setViewed(id, false)
        expandedId = nil
        reconcileSelection()
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

    /// The next of `ids` to visit (the HUD counters, ⌘J): oldest activity first, moving on from the
    /// tile the user is on.
    public func next(in ids: Set<String>) -> String? {
        ids.compactMap(info).next(after: selectedId)
    }

    /// Claude and Codex conversations open straight in their app; Tessera's transcript panel is only
    /// for when that app isn't installed, or when asked for. (dsh's live page lives in the panel.)
    public func opensInApp(_ id: String) -> Bool { app(opening: id) != nil }

    private func app(opening id: String, inApp: Bool = true) -> AgentApp? {
        agents.session(id).flatMap { AgentApp.opening($0.flavor, installed: installedApps, inApp: inApp) }
    }

    /// Open a desktop-app conversation in its own app, placed at `rect` (AppKit screen coordinates).
    public func openNative(_ id: String, at rect: CGRect?) {
        guard let a = agents.session(id) else { return }
        agentAcknowledged[id] = Date()
        if a.flavor == .dsh { return openDsh(a) }
        guard let app = AgentApp(flavor: a.flavor) else { return }
        WindowPlacer.open(a.openURL, bundleID: app.bundleID, placeAt: placeNativeWindows ? rect : nil)
    }

    // MARK: New app conversations

    /// A conversation just started in a desktop app: when its tile appears, it joins the tab it was
    /// started from and is selected.
    @ObservationIgnored private var pendingAppConversation: (app: AgentApp, since: Date, tab: String?)?

    /// Starts a new conversation in the Claude or Codex app (in `folder`, with `prompt` placed in its
    /// composer), placing the app window at `rect` (AppKit screen coordinates) when allowed.
    public func newAppConversation(_ app: AgentApp, folder: String?, prompt: String? = nil, placeAt rect: CGRect? = nil) {
        guard let url = app.newConversationURL(folder: folder, prompt: prompt) else { return }
        pendingAppConversation = (app, Date(), tabForNewTiles())
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
        if let tab = pending.tab { groups.assign(match.id, to: tab) }
        // The app already shows it; the board just points at its new tile, where that is on show.
        if visibleIds.contains(match.id) { selectedId = match.id }
        save()
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
        return TileInfo(id: a.id, kind: .agentSession, flavor: a.flavor, title: agentTitles[a.id] ?? a.title,
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
        let newest = live.values.map(\.session).sorted { $0.lastActivityAt > $1.lastActivityAt }
        var added: [AgentAppSession] = []
        for a in newest where !order.contains(a.id) {
            if let hidden = hiddenAgents[a.id], a.lastActivityAt <= hidden { continue }
            hiddenAgents[a.id] = nil
            if agentAcknowledged[a.id] == nil { agentAcknowledged[a.id] = .distantPast }
            order.insert(a.id, at: Self.restoredIndex(of: a.id, saved: savedOrder, in: order))
            added.append(a)
        }
        openPendingAppConversation(newlyAdded: added)
        // Write only a real change: even an empty removal would re-render everything reading `order`.
        let kept = order.filter { id in !(id.contains(":") && live[id] == nil && terminals[id] == nil && browsers[id] == nil) }
        if kept.count != order.count {
            order = kept
            if let e = expandedId, !order.contains(e) { expandedId = nil }
        }
        reconcileSelection()
    }

    private func agentsChanged() {
        syncAgents()
        if usage.codexRateLimits != agents.codexRateLimits { usage.codexRateLimits = agents.codexRateLimits }
    }

    private func adopt(_ session: TerminalSession) {
        session.onResumableChange = { [weak self] in self?.save() }
        session.onOpenLink = { [weak self] url in self?.onLink?(url) }
        terminals[session.id] = session
    }

    // MARK: Session binding

    @ObservationIgnored private var binding = false
    @ObservationIgnored private var bindPasses = 0

    /// Agents whose conversation id isn't known yet (Codex, or anything typed into a shell or started
    /// through a launcher) are matched to the session file their tool writes.
    private func bindAgentSessions() {
        guard !binding else { return }
        bindPasses &+= 1
        let now = Date()
        // Keep looking for as long as the agent runs: a conversation may start long after launch.
        let waiting = terminals.values.filter { $0.isRunning && !$0.isSuspended && $0.sessionId == nil }
        func candidates(_ tool: SessionResume.Tool) -> [SessionBinding.Candidate] {
            SessionBinding.unambiguous(waiting.filter { $0.command.flatMap(SessionResume.tool(for:)) == tool }
                .map { SessionBinding.Candidate(tileId: $0.id, cwd: $0.cwd, launchedAt: $0.launchedAt,
                                                continuing: $0.command.map(SessionResume.continuesLatest) ?? false) })
                // After ten minutes unbound it rarely happens, so those are looked for once a minute.
                .filter { now.timeIntervalSince($0.launchedAt) < 600 || bindPasses % 12 == 0 }
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
        var tiles: [Lossy<Tile>]
        var defaultDirectory: String?
        var placeNativeWindows: Bool?
        var groups: [TileGroup]?
        var resumeOnLaunch: Bool?
        /// Every tile's place, app sessions included (they aren't in `tiles`).
        var order: [String]?
        /// App sessions the user closed, and when.
        var hidden: [String: Date]?
        var agentLookbackHours: Double?
        /// Names the user gave app sessions (a terminal's or page's is in its tile).
        var titles: [String: String]?
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
            if let b = browsers[id] { return .init(id: id, kind: .browser, title: b.customTitle, url: b.url?.absoluteString) }
            return nil
        }
        // App sessions not on the board now (closed, or not rescanned yet since launch) keep their places.
        savedOrder = Self.persistedOrder(order, saved: savedOrder) { [agents] id in
            agents.sessions[id] != nil || (!agents.hasScanned && id.contains(":"))
        }
        // Closed longer ago than the lookback: that session can't be on the board anyway.
        let now = Date()
        hiddenAgents = hiddenAgents.filter { now.timeIntervalSince($0.value) < agents.lookback }
        // A name lasts as long as its session is remembered at all.
        for id in agentTitles.keys where !savedOrder.contains(id) { agentTitles[id] = nil }
        StateFile.save(Saved(tiles: tiles.map(Lossy.init), defaultDirectory: defaultDirectory, placeNativeWindows: placeNativeWindows,
                             groups: groups.list, resumeOnLaunch: resumeOnLaunch, order: savedOrder, hidden: hiddenAgents,
                             agentLookbackHours: agents.lookback / 3600, titles: agentTitles), to: saveURL)
    }

    /// Where a tile that reappears (an app session found again after launch) goes: right after the
    /// nearest tile that preceded it when saved, at the front if none of those is on the board, or at
    /// the end if it was never saved.
    nonisolated static func restoredIndex(of id: String, saved: [String], in order: [String]) -> Int {
        guard let i = saved.firstIndex(of: id) else { return order.endIndex }
        for previous in saved[..<i].reversed() {
            if let j = order.firstIndex(of: previous) { return j + 1 }
        }
        return 0
    }

    /// The board's order plus the saved ids `keep` wants remembered, each at its old place.
    nonisolated static func persistedOrder(_ order: [String], saved: [String], keep: (String) -> Bool) -> [String] {
        var result = order
        for id in saved where !result.contains(id) && keep(id) {
            result.insert(id, at: restoredIndex(of: id, saved: saved, in: result))
        }
        return result
    }

    private func restore() {
        guard let saved = StateFile.load(Saved.self, from: saveURL) else { return }
        // A tile this build can't read (say, a kind from a newer Tessera) drops out alone; the file is kept.
        let tiles = saved.tiles.compactMap(\.value)
        if tiles.count < saved.tiles.count { StateFile.keepAside(saveURL) }
        defaultDirectory = saved.defaultDirectory ?? defaultDirectory
        placeNativeWindows = saved.placeNativeWindows ?? true
        groups = TileGroups(saved.groups ?? [])
        resumeOnLaunch = saved.resumeOnLaunch ?? true
        savedOrder = saved.order ?? []
        hiddenAgents = saved.hidden ?? [:]
        agentTitles = saved.titles ?? [:]
        if let hours = saved.agentLookbackHours, AgentAppWatcher.lookbackHours.contains(hours) { agents.lookback = hours * 3600 }
        // One tile per conversation; "continue latest" only where it can't collide (see RestorePlan).
        let plan = RestorePlan.plan(tiles.filter { $0.kind == .terminal }.map { tile in
            RestorePlan.Tile(id: tile.id, command: tile.command, cwd: tile.cwd ?? defaultDirectory, sessionId: tile.sessionId)
        })
        for tile in tiles {
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
                    let b = BrowserSession(id: tile.id, url: url, title: tile.title)
                    browsers[b.id] = b
                    order.append(b.id)
                }
            case .agentSession:
                break
            }
        }
        selectedId = order.first
    }
}
