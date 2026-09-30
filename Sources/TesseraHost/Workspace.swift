import AppKit
import Foundation
import Observation
import TesseraKit

/// The board: every tile, its order, what is open, and what needs the user.
@Observable
@MainActor
public final class Workspace {
    /// The tab the board shows: everything, or one of the user's own.
    public enum Filter: Hashable, Sendable {
        case all, group(String)
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
    /// The tiles kept open beside the board. A docked tile's terminal or page lives there, and
    /// nowhere else: opening it goes to the dock.
    public private(set) var dock = WatchDock()
    /// How wide the user made the dock; nil until they have. (Saved with the board: see `save`.)
    public var dockWidth: CGFloat?
    public var filter: Filter = .all { didSet { reconcileSelection() } }
    /// What the filter field and its chips narrow the board to, in the tab being viewed.
    public var query = BoardQuery() { didSet { queryChanged(from: oldValue) } }
    /// Which tiles each filter chip holds; kept current as tiles change, like `state`.
    public private(set) var holdings = BoardQuery.Holdings()
    /// The tiles the typed text finds, as of its last keystroke; nil with nothing typed.
    private var found: Set<String>?
    /// What each tile showed when the typing began, so that no keystroke reads a screen again.
    @ObservationIgnored private var shownText: [String: String]?
    /// How many times the filter's text has been set by anything but typing in its field (typing on
    /// the board, Esc, a new tile): the field takes each up once, and is otherwise left to its typing.
    public private(set) var textSets = 0
    @ObservationIgnored private var typingInField = false
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
    /// Tiles closed lately, newest first: Undo and ⌘K's "Reopen …" bring one back (see `reopen`).
    public private(set) var recentlyClosed = RecentlyClosed<ClosedTile>()
    /// What was opened lately, for ⌃Tab.
    @ObservationIgnored private var opened = OpenHistory()
    /// The tile ⌘J or a HUD counter last went to (see `next(in:)`).
    @ObservationIgnored private var visited: TileInfo?

    /// A link clicked in a terminal (e.g. the URL a dev server or `dsh web` prints): the app opens
    /// it as a web tile.
    @ObservationIgnored public var onLink: ((URL) -> Void)?

    /// Observed: acknowledging an agent session changes how its tile looks.
    private var agentAcknowledged: [String: Date] = [:]
    /// Names the user gave app sessions (terminals and pages carry their own).
    private var agentTitles: [String: String] = [:]
    /// Conversations whose question the user set aside, and when: until it moves on, it isn't asking.
    private var agentDismissed: [String: Date] = [:]
    /// Observed: the tab strip offers them back.
    private var hiddenAgents: [String: Date] = [:]
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
        observe({ [weak self] in
            let tiles = self?.allTiles ?? []
            return (BoardState(tiles), BoardQuery.holdings(of: tiles))
        }) { [weak self] state, holdings in
            guard let self, self.state != state || self.holdings != holdings else { return }
            if self.state != state { self.state = state }
            if self.holdings != holdings { self.holdings = holdings }
            // A board its chips narrow shows only what still belongs: a tile that leaves (one that
            // stops waiting, under Needs you) takes the selection off with it.
            reconcileSelection()
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

    /// The tiles the board shows, in order: the tab's, narrowed by the filter. Reads membership and
    /// `holdings`, not every tile's data.
    public var visibleIds: [String] {
        // (Unfiltered, the board doesn't depend on what the chips hold.)
        query.isEmpty ? tabIds : query.narrow(tabIds, found: found, holdings: holdings, keeping: expandedId)
    }

    /// The number on a filter chip (see `BoardQuery.count`).
    public func count(_ chip: BoardQuery.Chip) -> Int {
        query.count(chip, in: tabIds, found: found, holdings: holdings)
    }

    /// How many tiles the chips have to narrow: the tab's, or those of them the typed text found.
    public var findable: Int {
        found.map { found in tabIds.filter(found.contains).count } ?? tabIds.count
    }

    /// The tiles of the tab being viewed, before the filter narrows them.
    public var tabIds: [String] {
        switch filter {
        case .all: return order
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

    /// New work belongs in the tab being viewed, and shows: the filter is dropped.
    private func tabForNewTiles() -> String? {
        if !query.isEmpty { query = BoardQuery() }
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
        // An open tile keeps the selection (a tile started from the phone mustn't take it).
        if expandedId == nil { selectedId = id }
        save()
    }

    /// Closes a terminal or page, keeping what brings it back (see `reopen`): an agent in it is
    /// stopped the way Shut Down stops it, its conversation kept. An app conversation is only hidden
    /// until it is active again. Returns what was closed.
    @discardableResult
    public func close(_ id: String) -> ClosedTile? {
        guard exists(id), let info = info(id) else { return nil }
        if expandedId == id { collapse() }
        dock.remove(id)
        let visible = visibleIds
        // Read before the terminal ends: its folder comes from the live process.
        let closed = ClosedTile(title: info.title, subtitle: info.subtitle, tile: savedTile(id) ?? .init(id: id, kind: info.kind),
                                tab: groups.group(of: id)?.id)
        if let t = terminals.removeValue(forKey: id) { t.terminate() }
        if let b = browsers.removeValue(forKey: id) { b.webView.stopLoading() }
        if agents.sessions[id] != nil { hiddenAgents[id] = Date() } else { groups.assign(id, to: nil) }
        // Its place as of now (an app session may have arrived since the board was last saved).
        rememberOrder()
        order.removeAll { $0 == id }
        if selectedId == id { selectedId = Self.neighbor(of: id, in: visible) }
        recentlyClosed.push(closed)
        save()
        return closed
    }

    /// Brings back a tile closed lately, or a hidden conversation, to where it was: a terminal picks
    /// its conversation up again in its folder, a page loads its address. False when there is
    /// nothing to bring back.
    @discardableResult
    public func reopen(_ id: String) -> Bool {
        let closed = recentlyClosed.take(id)
        guard !exists(id) else { return false }
        if hiddenAgents.removeValue(forKey: id) != nil {
            syncAgents()
        } else if let closed, revive(closed.tile, as: restorePlan(order.compactMap(savedTile) + [closed.tile])[id],
                                     suspended: closed.tile.suspended == true) {
            order.insert(id, at: Self.restoredIndex(of: id, saved: savedOrder, in: order))
            groups.assign(id, to: closed.tab)
        }
        guard exists(id) else { return false }
        // An open tile keeps the selection.
        if expandedId == nil { select(id) }
        save()
        return true
    }

    /// How many hidden conversations and closed tiles can be brought back (cheap: reads no tile).
    public var putAwayCount: Int {
        hiddenAgents.keys.filter { agents.sessions[$0] != nil }.count + closedTiles.count
    }

    /// Tiles closed lately that can be reopened (a hidden conversation is listed as hidden, not here).
    public var closedTiles: [ClosedTile] { recentlyClosed.tiles.filter { hiddenAgents[$0.id] == nil } }

    /// Conversations the user hid that can be shown again, the latest first.
    public var hiddenTiles: [TileInfo] {
        hiddenAgents.keys.compactMap { agents.session($0) }.map(agentInfo).sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// The tiles `command` would act on now: those on show in the tab being viewed (in every tab,
    /// for Shut Down All and Resume All), and for Show Hidden Conversations the hidden ones filed there.
    public func targets(of command: BoardCommand) -> [String] {
        if command == .showHidden {
            guard case .group(let tab) = filter else { return hiddenTiles.map(\.id) }
            return hiddenTiles.map(\.id).filter(groups.members(of: tab).contains)
        }
        return (command.everyTab ? order : visibleIds).filter { id in
            info(id).map { command.applies(to: $0, suspended: isSuspended(id)) } ?? false
        }
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

    /// Selects a tile. When the board isn't showing it, the filter is dropped, and if it is in
    /// another tab, the view goes to All.
    public func select(_ id: String) {
        guard exists(id) else { return }
        if !visibleIds.contains(id) { query = BoardQuery() }
        if !visibleIds.contains(id) { filter = .all }
        selectedId = id
    }

    // MARK: The filter

    /// The filter field's own edit.
    public func typeFilter(_ text: String) {
        typingInField = true
        query.text = text
        typingInField = false
    }

    /// Typing selects the first tile it finds (⏎ opens it); a chip only keeps the selection on show.
    private func queryChanged(from old: BoardQuery) {
        guard query != old else { return }
        if query.text != old.text {
            if !typingInField { textSets &+= 1 }
            if !query.hasText { shownText = nil } else if shownText == nil { shownText = readShownText() }
            let tabs = groups
            found = query.find(in: allTiles.map { tile in
                TileSearch.Candidate(tile: tile, tab: tabs.group(of: tile.id)?.name, text: shownText?[tile.id] ?? "")
            })
            if found != nil, expandedId == nil, let first = visibleIds.first { selectedId = first }
        }
        reconcileSelection()
    }

    /// What each tile shows: a terminal's screen, a conversation's latest messages, a page's address.
    private func readShownText() -> [String: String] {
        var text: [String: String] = [:]
        for (id, session) in terminals { text[id] = session.terminal.screenTail(session.terminal.rows).joined(separator: "\n") }
        for (id, page) in browsers { text[id] = page.info.url }
        for id in order where id.contains(":") {
            text[id] = agents.session(id)?.snapshot.items.suffix(20).map(\.text).joined(separator: "\n")
        }
        return text
    }

    /// A one-tap answer to a terminal's question, from the Needs-you lane: typed into it unopened.
    public func answer(_ id: String, with answer: QuickAnswer) {
        terminals[id]?.send(answer.bytes)
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
        opened.note(id)
        if app(opening: id, inApp: inApp) != nil {
            collapse()
            select(id)
            openNative(id, at: rect)
        } else if dock.contains(id) {
            // It is open already, in the dock: that is where the user is sent.
            collapse()
            select(id)
            acknowledge(id)
        } else {
            if let prev = expandedId, prev != id { setViewed(prev, false) }
            select(id)
            expandedId = id
            setViewed(id, true)
        }
    }

    // MARK: The dock

    /// Docks a tile beside the board, or takes it out again. Docked, it is on show: an open panel
    /// of it closes, and it counts as being looked at. A full dock lets its oldest tile go.
    public func setDocked(_ id: String, _ docked: Bool) {
        guard docked ? exists(id) && !dock.contains(id) : dock.contains(id) else { return }
        var left: String?
        if docked {
            if expandedId == id { collapse() }
            left = dock.add(id)
        } else {
            dock.remove(id)
        }
        for id in [left, id].compactMap({ $0 }) { setViewed(id, dock.contains(id)) }
        fit([left, id])
        save()
    }

    /// Takes a docked tile out of the dock and opens it full size (a Claude or Codex conversation:
    /// its transcript).
    public func openFromDock(_ id: String) {
        guard dock.remove(id) else { return }
        open(id, inApp: false)
        fit([id])
        save()
    }

    /// A docked terminal is drawn smaller. This comes last in whatever an action does: the new font
    /// lays the terminal out there and then, and SwiftUI, redrawing at once for that, would show
    /// the board without a change made to it afterwards.
    private func fit(_ ids: [String?]) {
        for id in ids.compactMap({ $0 }) { terminals[id]?.setCompact(dock.contains(id)) }
    }

    /// Whether the user has the tile's content in front of them: open, or docked.
    public func isOnShow(_ id: String) -> Bool { expandedId == id || dock.contains(id) }

    /// The docked tiles there are to show, in the dock's order.
    public var docked: [String] { dock.ids.filter(exists) }

    /// Where ⌃Tab goes: the latest tile opened that isn't the one the user is on.
    public var previousTile: String? { opened.previous(from: expandedId ?? selectedId, where: exists) }

    /// Back to the board; the tile stays selected.
    public func collapse() {
        guard let id = expandedId else { return }
        expandedId = nil
        setViewed(id, isOnShow(id))
        reconcileSelection()
    }

    public func acknowledge(_ id: String) {
        terminals[id]?.acknowledge()
        browsers[id]?.acknowledge()
        if agents.sessions[id] != nil { agentAcknowledged[id] = Date() }
    }

    /// Takes a tile out of what needs the user without answering it (Mark as Seen, Dismiss): its
    /// result counts as seen, its question as set aside until the next one.
    public func dismiss(_ id: String) {
        acknowledge(id)
        terminals[id]?.dismissQuestion()
        if agents.sessions[id] != nil { agentDismissed[id] = Date() }
    }

    private func setViewed(_ id: String, _ viewed: Bool) {
        terminals[id]?.setViewed(viewed)
        browsers[id]?.setViewed(viewed)
        if agents.sessions[id] != nil { agentAcknowledged[id] = Date() }
    }

    /// The next of `ids` to visit (the HUD counters, ⌘J): the first, or moving on from the tile the
    /// user is on once they have seen it — as they have an app conversation that opened in its app.
    public func next(in ids: Set<String>) -> String? {
        // Opened, the tile last visited may have stopped waiting: it is passed as it was then.
        let current = visited?.id == selectedId ? visited : selectedId.flatMap(info)
        visited = ids.compactMap(info).next(after: current).flatMap(info)
        return visited?.id
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
        if expandedId == nil, visibleIds.contains(match.id) { selectedId = match.id }
        save()
    }

    // MARK: DeepSeek Harness

    /// The dsh web UI, shown inside whichever dsh session's panel is open. It's one shared page,
    /// never a tile of its own, so a session never appears twice on the board.
    public private(set) var dshPage: BrowserSession?
    /// The session that page shows: the one last opened in it.
    public private(set) var dshSession: String?

    /// Brings up dsh web (starting Tessera's server if needed; the first load uses the token URL,
    /// which signs the page in) and selects this session in it.
    private func openDsh(_ session: AgentAppSession) {
        dshSession = session.id
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
        let unseen = a.snapshot.activity.isAttention && last > ack && !isOnShow(a.id)
        // Finished work the user has already seen is just idle, same as a terminal; so is a question
        // set aside, until the conversation moves on.
        let dismissed = agentDismissed[a.id].map { $0 >= last } ?? false
        let activity: TileActivity = (a.snapshot.activity == .done && !unseen) || (a.snapshot.activity == .needsInput && dismissed)
            ? .idle : a.snapshot.activity
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
            if let hidden = hiddenAgents[a.id] {
                if a.lastActivityAt <= hidden { continue }
                // Active again, it is back by itself: there is nothing left to undo.
                hiddenAgents[a.id] = nil
                _ = recentlyClosed.take(a.id)
            }
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
        // A docked conversation that is gone leaves the dock (one not found yet since launch is waited for).
        if agents.hasScanned { for id in dock.ids where !order.contains(id) { setDocked(id, false) } }
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

    private var saveURL: URL { directory.appendingPathComponent("workspace.json") }

    public func save() {
        var savedIds: Set<String> = []
        let tiles: [Saved.Tile] = order.compactMap(savedTile).map { tile in
            // Never record one conversation for two tiles; the later one will start fresh.
            var tile = tile
            tile.sessionId = tile.sessionId.flatMap { savedIds.insert($0).inserted ? $0 : nil }
            return tile
        }
        rememberOrder()
        // Closed longer ago than the lookback: that session can't be on the board anyway.
        let now = Date()
        let remembered = hiddenAgents.filter { now.timeIntervalSince($0.value) < agents.lookback }
        if remembered.count != hiddenAgents.count { hiddenAgents = remembered }
        // A name lasts as long as its session is remembered at all.
        for id in agentTitles.keys where !savedOrder.contains(id) { agentTitles[id] = nil }
        StateFile.save(Saved(tiles: tiles.map(Lossy.init), defaultDirectory: defaultDirectory, placeNativeWindows: placeNativeWindows,
                             groups: groups.list, resumeOnLaunch: resumeOnLaunch, order: savedOrder, hidden: hiddenAgents,
                             agentLookbackHours: agents.lookback / 3600, titles: agentTitles,
                             closed: recentlyClosed.tiles.map(Lossy.init), dock: dock.ids,
                             dockWidth: dockWidth.map(Double.init)), to: saveURL)
    }

    /// Notes every tile's place. App sessions not on the board now (closed, or not rescanned yet
    /// since launch) keep theirs, as do tiles closed lately, for when they come back.
    private func rememberOrder() {
        let closed = Set(recentlyClosed.tiles.map(\.id))
        savedOrder = Self.persistedOrder(order, saved: savedOrder) { [agents] id in
            closed.contains(id) || agents.sessions[id] != nil || (!agents.hasScanned && id.contains(":"))
        }
    }

    /// What it takes to bring a terminal or page back, as it is now.
    private func savedTile(_ id: String) -> Saved.Tile? {
        if let t = terminals[id] {
            return .init(id: id, kind: .terminal, command: t.command, cwd: t.liveDirectory() ?? t.cwd, title: t.customTitle,
                         sessionId: t.sessionId, suspended: t.isSuspended)
        }
        if let b = browsers[id] { return .init(id: id, kind: .browser, title: b.customTitle, url: b.url?.absoluteString) }
        return nil
    }

    /// One tile per conversation; "continue latest" only where it can't collide (see RestorePlan).
    private func restorePlan(_ tiles: [Saved.Tile]) -> [String: RestorePlan.Decision] {
        RestorePlan.plan(tiles.filter { $0.kind == .terminal }.map { tile in
            RestorePlan.Tile(id: tile.id, command: tile.command, cwd: tile.cwd ?? defaultDirectory, sessionId: tile.sessionId)
        })
    }

    /// Makes a saved terminal or page a tile again (at launch, or reopened after a close); false
    /// when it can't be. Its place on the board is the caller's to give.
    private func revive(_ tile: Saved.Tile, as decision: RestorePlan.Decision?, suspended: Bool) -> Bool {
        switch tile.kind {
        case .terminal:
            let cwd = tile.cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? defaultDirectory
            let decision = decision ?? RestorePlan.Decision(sessionId: nil, mayContinueLatest: false)
            adopt(TerminalSession(id: tile.id, command: tile.command, cwd: cwd, title: tile.title, label: tile.command,
                                  sessionId: decision.sessionId, resuming: true, mayContinueLatest: decision.mayContinueLatest,
                                  startSuspended: suspended))
        case .browser:
            guard let url = tile.url.flatMap(URL.init(string:)) else { return false }
            browsers[tile.id] = BrowserSession(id: tile.id, url: url, title: tile.title)
        case .agentSession:
            return false
        }
        return true
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
        recentlyClosed = RecentlyClosed(saved.closed?.compactMap(\.value) ?? [])
        let plan = restorePlan(tiles)
        for tile in tiles where revive(tile, as: plan[tile.id], suspended: tile.suspended == true || !resumeOnLaunch) {
            order.append(tile.id)
        }
        selectedId = order.first
        // The dock as it was left (a docked app conversation is found again after launch); what is
        // in it is looked at from the start.
        dock = WatchDock((saved.dock ?? []).filter { order.contains($0) || $0.contains(":") })
        dockWidth = saved.dockWidth.map { CGFloat($0) }
        for id in dock.ids { setViewed(id, true) }
        fit(dock.ids)
    }
}
