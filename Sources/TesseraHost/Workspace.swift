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

    public enum BoardSort: String, CaseIterable { case recent, manual }
    public var boardSort = BoardSort(rawValue: Preferences.store.string(forKey:"tessera.boardSort") ?? "recent") ?? .recent {
        didSet { Preferences.store.set(boardSort.rawValue,forKey:"tessera.boardSort") }
    }
    private var recentlyUsed = Preferences.store.stringArray(forKey:"tessera.recentTasks") ?? []
    private var arrivalActivity: [String:Date] = [:]
    public private(set) var order: [String] = []
    public private(set) var terminals: [String: TerminalSession] = [:]
    public private(set) var browsers: [String: BrowserSession] = [:]
    public let agents = AgentAppWatcher()
    public let accord: AccordBridge
    /// Shared local dsh web page used to select a live conversation from its sidebar.
    public let dsh = DshWebServer()
    public let usage: UsageService
    public let machines: MachineMonitor
    /// A LLooM head's leases and agents' jobs (the Fleet band; jobs are tiles).
    public let fleet: FleetService
    /// What agents leave for the user and each other (questions, notes, messages).
    public let desk: AgentDesk
    /// The model that summarizes tiles and briefs the board.
    public let steward: StewardService
    /// The overseer's conversation, watched for its panel.
    public let overseerChat = OverseerChat()
    /// Tessera's API for agents on this Mac (MCP over loopback; the `tessera` command).
    public let agentTools = AgentTools()
    public let agentServer: AgentServer
    /// When the user last went away from Tessera (the app stopped being frontmost): the brief says
    /// what happened since.
    public var awaySince = Date()
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
    public var placeNativeWindows = false
    /// Bring terminals back into their conversations when Tessera opens (else they wait, shut down).
    public var resumeOnLaunch = true
    public var defaultDirectory: String = NSHomeDirectory()
    /// The folders tiles were started in lately, the latest first; the launcher offers them again.
    public var recentDirectories: [String] { startedIn.filter(StartFolders.isFolder) }
    private var startedIn = Preferences.store.stringArray(forKey: "tessera.recentDirectories") ?? []
    /// The overseer's tile (see `overseer`), and the agent that runs in a new one.
    public private(set) var overseerId: String?
    public var overseerCommand = Preferences.store.string(forKey: "tessera.overseerCommand") ?? Overseer.defaultCommand {
        didSet { Preferences.store.set(overseerCommand, forKey: "tessera.overseerCommand") }
    }
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
    /// Routes a close asked for by an agent through the app's UI path (toast, Undo); tests leave
    /// it nil and the workspace closes directly.
    @ObservationIgnored public var onAgentClose: ((String, String) -> Void)?

    /// Observed: acknowledging an agent session changes how its tile looks.
    private var agentAcknowledged: [String: Date] = [:]
    /// The latest name each bound agent session's own store reports (Claude transcript
    /// `customTitle`, Codex `thread_name`, Devin `sessions.title`): the origin's title.
    /// A failed read keeps the last value, so a locked store doesn't flicker a tile.
    private var storeTitles: [String: String] = [:]
    /// The Codex app-server rename; tests substitute their own.
    @ObservationIgnored var codexRenameThread: (String, String) async throws -> Void = { thread, name in
        try await CodexAppServer.renameThread(thread, to: name)
    }
    /// Conversations whose question the user set aside, and when: until it moves on, it isn't asking.
    private var agentDismissed: [String: Date] = [:]
    /// Observed: the tab strip offers them back.
    private var hiddenAgents: [String: Date] = [:]
    /// The order last saved, app sessions included: they take their places again as they reappear.
    @ObservationIgnored private var savedOrder: [String] = []
    @ObservationIgnored private let attentionBaseline = Date()
    @ObservationIgnored private let directory: URL

    public init(accordProfile: URL? = nil) {
        var bridgeProfile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/accord/connection.json")
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tessera")
        // Isolated debug and packaged-release instances never share the live board.
        if let override = ProcessInfo.processInfo.environment["TESSERA_DATA_DIR"] {
            dir = URL(fileURLWithPath: override)
            bridgeProfile = dir.appendingPathComponent("accord-connection.json")
        }
        directory = dir
        accord = AccordBridge(profile: accordProfile ?? bridgeProfile)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        boardHolder = BoardLock.take(in: directory)
        usage = UsageService(directory: directory)
        machines = MachineMonitor(directory: directory)
        fleet = FleetService(directory: directory)
        desk = AgentDesk(directory: directory)
        steward = StewardService(directory: directory)
        agentServer = AgentServer(directory: directory, tools: agentTools)
        desk.closeApproved = { [weak self] request in self?.answerClose(request, approved: true) }
        desk.closeDeclined = { [weak self] request in self?.answerClose(request, approved: false) }
    }

    public func start() {
        restore()
        observe({ [weak self] in
            let tiles = self?.taskTiles ?? []
            let board = self?.boardTiles ?? []
            var state = BoardState(tiles)
            // The overseer counts where it waits (asking, failed: the lane and ⌘J lead to it) —
            // never as a result to review — but it isn't on the board: not as a working tile, and
            // not in the chips.
            state.withoutReview(of: self?.overseerId)
            state.working.formIntersection(board.map(\.id))
            return (state, BoardQuery.holdings(of: board))
        }) { [weak self] state, holdings in
            guard let self, self.state != state || self.holdings != holdings else { return }
            if self.state != state { self.state = state }
            if self.holdings != holdings { self.holdings = holdings }
            // A board its chips narrow shows only what still belongs: a tile that leaves (one that
            // stops waiting, under Needs you) takes the selection off with it.
            reconcileSelection()
            // A tile that just went idle can take the next queued wake message.
            pumpWakes()
        }
        agents.onChange = { [weak self] in self?.agentsChanged() }
        agents.start()
        usage.start()
        machines.accord = accord
        machines.start()
        fleet.onChange = { [weak self] in self?.fleetChanged() }
        fleet.accord = accord
        fleet.start()
        desk.onChange = { [weak self] in self?.deskChanged() }
        desk.typeInto = { [weak self] id, text in self?.typeMessage(text, into: id) ?? false }
        deskChanged()
        // The overseer is not stewarded (its card stands for it), but it stays reported to Accord.
        steward.digests = { [weak self] in self?.stewardDigests().filter { $0.id != self?.overseerId } ?? [] }
        steward.changes = { [weak self] in self.map { Steward.changes($0.allTiles, since: $0.awaySince) } ?? [] }
        steward.sharedSummaries = { [weak self] in self?.accord.tileSummaries ?? [:] }
        steward.configureShared = { [weak self] config, key, migration in
            guard let self else { return }
            var args: [String:Any] = ["url":config.url,"model":config.model,"ifAbsent":migration]
            if let key, !key.isEmpty { args["key"] = key }
            _ = try await self.accord.request("summary-configure", args:args)
        }
        steward.start()
        overseerChat.attach(self)
        overseerChat.start()
        accord.digests = { [weak self] in self?.stewardDigests().filter { !$0.id.hasPrefix("accord:") && ![AgentFlavor.lloom.rawValue, AgentFlavor.agentDesk.rawValue, AgentFlavor.accord.rawValue].contains($0.flavor) } ?? [] }
        accord.presentTiles = { [weak self] in self?.presentTileIDs ?? [] }
        accord.overseerTile = { [weak self] in self?.overseerId }
        accord.logFailure = { [weak self] text in
            self.map { TileLog.append(in: $0.directory, file: "accord.log",
                                      fields: ["at": ISO8601DateFormatter().string(from: Date()), "event": "accord-call-failed", "detail": text]) }
        }
        accord.sweepRefused = { [weak self] text in
            self.map { TileLog.append(in: $0.directory, file: "accord.log",
                                      fields: ["at": ISO8601DateFormatter().string(from: Date()), "event": "closed-sweep-skipped", "detail": text]) }
        }
        accord.nativeAliases = { [weak self] in self?.nativeSessionAliases ?? [] }
        accord.lookback = { [weak self] in self?.agents.lookback ?? 36 * 3600 }
        accord.sessions = { [weak self] values in self?.agents.setExternal(values, source: "accord") }
        accord.paused = { [weak self] in self?.agentTools.privacy() ?? true }
        desk.onRenameFailed = { [weak self] message, reason in
            Task { await self?.renameFailed(message.to, to: "", notify: message.fromAddress, reason: reason) }
        }
        accord.renameInfo = { [weak self] id in self?.renameReport(id) }
        accord.renameTile = { [weak self] tile, title, sender, delivery in
            self?.renameDelivery(tile: tile, title: title, sender: sender, deliveryId: delivery) ?? false
        }
        accord.deliver = { [weak self] delivery, tile, sender, text, wantsTyping in
            guard let self, let info = self.info(tile) else { return false }
            let senderTile = self.tileForSender(sender)
            let kind = self.wakeKind(forTile: senderTile)
            let label = senderTile.flatMap { self.info($0)?.title } ?? sender
            return self.desk.importMessage(id: "accord:" + delivery, text: text, from: label, address: sender, tile: senderTile,
                                           to: tile, title: info.title, route: self.wakeRoute(for: tile, kind: kind, wantsTyping: wantsTyping))
        }
        desk.openWithText = { [weak self] tile, text in
            guard let self else { return false }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self.openNative(tile, at: nil)
            return true
        }
        accord.questions = { [weak self] questions in self?.desk.importAccordQuestions(questions) }
        accord.notes = { [weak self] in self?.desk.importAccordNotes($0) }
        accord.noteReads = { [weak self] in self?.desk.accordNoteReads() ?? [] }
        accord.noteRead = { [weak self] in self?.desk.confirmNoteRead($0) }
        accord.answers = { [weak self] in self?.desk.accordAnswers() ?? [] }
        accord.start()
        agentTools.attach(self)
        agentServer.start()
        DispatchQueue.global(qos: .utility).async {
            let found = LaunchCatalog.detectInstalled()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.presets = found } }
        }
        let binder = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for t in self.terminals.values { t.noteForegroundAgent() }
                self.bindAgentSessions()
                self.refreshOriginTitles()
            }
        }
        binder.tolerance = 1
        RunLoop.main.add(binder, forMode: .common)
        if order.isEmpty { launch(command: nil) }
    }

    // MARK: Tiles

    public func info(_ id: String) -> TileInfo? {
        var info: TileInfo
        if let t = terminals[id] { info = t.info } else if let b = browsers[id] { info = b.info } else if let a = agents.session(id) {
            info = agentInfo(a)
        } else {
            return nil
        }
        // Agent terminals take their title from the origin: the bound session's own store when
        // one is known, else what the program itself last set (OSC). Tessera names and Accord
        // records never title them.
        if let t = terminals[id], t.command.flatMap(SessionResume.conversationTool(for:)) != nil {
            info.title = storeTitles[id] ?? t.title
        }
        info.summary = accord.summaries[id] ?? steward.summaries[id]?.summary
        info.needs = steward.summaries[id]?.needs ?? steward.brief?.attention.first { $0.id == id }?.why
        let children = relatedSessions(id)
        if let waiting = children.first(where: { agentInfo($0).activity == .needsInput }) {
            info.activity = .needsInput
            info.needs = waiting.snapshot.detail ?? waiting.title
            info.attention = true
        } else if children.contains(where: { agentInfo($0).activity == .working }), ![TileActivity.needsInput,.failed].contains(info.activity) {
            info.activity = .working
        }
        if info.needs?.isEmpty == true { info.needs = nil }
        info.wake = desk.wakeMark(for: id)
        return info
    }

    /// Whether `id` is on the board (a closed app session is still known, but not on it). Unlike
    /// `info`, this doesn't read (or observe) the tile's data.
    public func exists(_ id: String) -> Bool { order.contains(id) }

    public var allTiles: [TileInfo] { order.compactMap(info) }
    public var taskIDs: [String] { order.filter { linkedConversation($0) == nil } }
    public var taskTiles: [TileInfo] { taskIDs.compactMap(info) }

    /// The board's tiles for counting and display: every task but the overseer, which lives in
    /// its own panel, not the grid. (`state`'s waiting sets still include it — the lane and ⌘J
    /// lead to it — so those are built from `taskTiles`, not this.)
    public var boardTiles: [TileInfo] { taskTiles.filter { $0.id != overseerId } }

    /// The tiles the board shows, in order: the tab's, narrowed by the filter. Reads membership and
    /// `holdings`, not every tile's data.
    public var visibleIds: [String] {
        // (Unfiltered, the board doesn't depend on what the chips hold.)
        let candidates = query.isEmpty ? tabIds : query.narrow(tabIds, found: found, holdings: holdings, keeping: expandedId)
        return candidates.filter { id in
            guard id != expandedId, let parent=linkedConversation(id) else { return true }
            return !candidates.contains(parent)
        }
    }

    /// The number on a filter chip (see `BoardQuery.count`).
    public func count(_ chip: BoardQuery.Chip) -> Int {
        query.count(chip, in: tabIds.filter { linkedConversation($0) == nil }, found: found, holdings: holdings)
    }

    /// How many tiles the chips have to narrow: the tab's, or those of them the typed text found.
    public var findable: Int {
        let tasks = tabIds.filter { linkedConversation($0) == nil }
        return found.map { found in tasks.filter(found.contains).count } ?? tasks.count
    }

    /// The tiles of the tab being viewed, before the filter narrows them.
    public var tabIds: [String] {
        let sorted = boardSort == .manual ? order : Self.taskOrder(order,recent:recentlyUsed,activity:arrivalActivity)
        let ids: [String]
        switch filter {
        case .all: ids = sorted
        case .group(let g):
            let members = groups.members(of: g)
            ids = sorted.filter { members.contains($0) || $0 == expandedId || linkedConversation($0).map(members.contains) == true }
        }
        // The overseer lives in its panel, never in a tab's tiles or counts.
        return ids.filter { $0 != overseerId }
    }

    /// Starts a terminal tile. `quietly` (an agent's `open_tile`) keeps the board as the developer
    /// left it — no query reset, no selection change, the tile filed in `tab` and placed after
    /// `after` (the caller's tile) or at the end.
    @discardableResult
    public func launch(command: String?, cwd: String? = nil, title: String? = nil,
                       quietly: Bool = false, tab: String? = nil, after: String? = nil) -> String {
        let session = TerminalSession(command: command, cwd: cwd ?? defaultDirectory, title: title)
        adopt(session)
        insert(session.id, quietly: quietly, tab: tab, after: after)
        if let cwd { noteDirectory(cwd) }
        return session.id
    }

    /// A tile was started in `dir`: the launcher offers it again. (The overseer's folder is its own.)
    public func noteDirectory(_ dir: String) {
        guard dir.standardizedPath != overseerDirectory.path.standardizedPath else { return }
        startedIn = StartFolders.remembering(dir, in: startedIn)
        Preferences.store.set(startedIn, forKey: "tessera.recentDirectories")
    }

    // MARK: The overseer

    /// The overseer's folder: its role is there for whichever agent runs in it.
    public var overseerDirectory: URL { directory.appendingPathComponent("overseer") }

    /// The overseer's tile, there to be talked to, with `question` put to it when there is one. It
    /// is started when there is none and brought back when it was shut down; one whose agent was
    /// quit is only a shell now, and is replaced. Nil when its folder can't be made.
    @discardableResult
    public func overseer(asking question: String? = nil) -> String? {
        if let id = overseerId, let terminal = terminals[id] {
            if terminal.command != nil {
                if !terminal.isRunning { resume(id) }
                if let question { type(question, intoAgent: id) }
                return id
            }
            close(id)
        }
        guard (try? Overseer.prepare(overseerDirectory)) != nil else { return nil }
        let typed = overseerCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = typed.isEmpty ? Overseer.defaultCommand : typed
        // A new one is handed its first question as it starts: the agent takes it up once it is
        // ready, after anything it asks first (whether to trust its folder). The tile's command
        // stays the agent alone, so that resuming never asks it again.
        let first = question.map { ShellWords.join(ShellWords.split(command) + [$0]) }
        let id = launch(command: first ?? command, cwd: overseerDirectory.path, title: Overseer.title)
        terminals[id]?.command = command
        overseerId = id
        save()
        return id
    }

    /// Types what the user asked into an agent that is already there. One started moments ago
    /// (resumed, or brought back as Tessera opened) is given time to come up first.
    private func type(_ text: String, intoAgent id: String) {
        guard let terminal = terminals[id] else { return }
        let wait = max(0, Self.agentStartup - Date().timeIntervalSince(terminal.launchedAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in _ = self?.typeMessage(text, into: id) }
    }

    /// How long an agent CLI is given to start before it is typed into.
    static let agentStartup: TimeInterval = 6

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

    private func insert(_ id: String, quietly: Bool = false, tab: String? = nil, after: String? = nil) {
        groups.assign(id, to: quietly ? tab : tabForNewTiles())
        // New tiles land after the selection so related work clusters.
        if let spot = (quietly ? after : selectedId), let i = order.firstIndex(of: spot) {
            order.insert(id, at: i + 1)
        } else {
            order.append(id)
        }
        // An open tile keeps the selection (a tile started from the phone mustn't take it);
        // an agent's quiet open leaves it alone too.
        if !quietly, expandedId == nil { selectedId = id }
        save()
    }

    /// Closes a terminal or page, keeping what brings it back (see `reopen`): an agent in it is
    /// stopped the way Shut Down stops it, its conversation kept. An app conversation is only hidden
    /// until it is active again. `by` names who asked — the developer, or an agent — for the log.
    /// Returns what was closed.
    @discardableResult
    public func close(_ id: String, by: String = "the developer") -> ClosedTile? {
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
        desk.setAside(id)
        // Its place as of now (an app session may have arrived since the board was last saved).
        rememberOrder()
        order.removeAll { $0 == id }
        if selectedId == id { selectedId = Self.neighbor(of: id, in: visible) }
        recentlyClosed.push(closed)
        CloseLog.append(in: directory, tile: id, title: info.title, kind: info.kind.rawValue, by: by, outcome: "closed")
        save()
        return closed
    }

    /// Brings back a tile closed lately, or a hidden conversation, to where it was: a terminal picks
    /// its conversation up again in its folder, a page loads its address. False when there is
    /// nothing to bring back.
    @discardableResult
    public func reopen(_ id: String, quietly: Bool = false) -> Bool {
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
        // An open tile keeps the selection, and an agent's reopen leaves it alone.
        if !quietly, expandedId == nil { select(id) }
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
        boardSort = .manual
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

    /// How this tile can be renamed at its origin, or why not.
    public func renameSupport(for id: String) -> RenameSupport {
        if let t = terminals[id] {
            return RenameSupport.support(kind: .terminal, flavor: t.flavor,
                                         agentRunning: t.isRunning, sessionId: t.sessionId)
        }
        if browsers[id] != nil { return .supported(.tessera) }
        if let a = agents.session(id) {
            return RenameSupport.support(kind: .agentSession, flavor: a.flavor, agentRunning: true,
                                         sessionId: a.id.hasPrefix("codex:") ? String(a.id.dropFirst(6)) : nil)
        }
        return .unsupported("This source can't be renamed: no such tile.")
    }

    /// What this tile reports to Accord as its rename support (`nil`: an older Accord ignores it).
    func renameReport(_ id: String) -> (String, String?) {
        switch renameSupport(for: id) {
        case .supported: return ("supported", nil)
        case .unsupported(let reason): return ("unsupported", reason)
        }
    }

    /// Rename — any tile — at its origin. `by` is the Accord address of the requester; nil is the
    /// user at the keyboard. Tessera-owned names apply at once (an empty name clears back to the
    /// origin's own); agent sources are typed at the idle prompt through the wake pipeline or
    /// asked of `codex app-server`; unsupported sources refuse. Returns what happened, for toasts.
    @discardableResult
    public func rename(_ id: String, to title: String, by sender: String? = nil) throws -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = info(id)?.title ?? id
        switch renameSupport(for: id) {
        case .unsupported(let reason):
            throw AgentTools.Refusal(reason)
        case .supported(.tessera):
            // Empty clears Tessera's name so the origin's own shows again.
            terminals[id]?.rename(name)
            browsers[id]?.rename(name)
            save()
            return name.isEmpty ? "Reverted to its own title." : "Renamed \(label) to \(name)."
        case .supported(.typed):
            guard let typed = RenameSupport.sanitizedName(name) else {
                throw AgentTools.Refusal("A name can't be removed at the source; give a new name.")
            }
            let senderTile = sender.flatMap(tileForSender)
            let route = sender == nil ? AgentDesk.Route.queued
                : wakeRoute(for: id, kind: wakeKind(forTile: senderTile), wantsTyping: true)
            guard route != .inbox else { throw AgentTools.Refusal("This sender can't reach that tile.") }
            desk.importMessage(id: "rename:local:\(UUID().uuidString)", text: "/rename \(typed)",
                               from: sender ?? "you", address: sender, tile: senderTile,
                               to: id, title: label, route: route)
            return "Will rename \(label) when \(terminals[id]?.flavor.displayName ?? "it") is idle."
        case .supported(.codexAppServer):
            guard let typed = RenameSupport.sanitizedName(name) else {
                throw AgentTools.Refusal("A name can't be removed at the source; give a new name.")
            }
            guard let session = terminals[id]?.sessionId ?? (agents.session(id)?.id.hasPrefix("codex:") == true ? String(id.dropFirst(6)) : nil) else {
                throw AgentTools.Refusal("This source can't be renamed: Codex has no bound conversation in this tile yet.")
            }
            let codexRenameThread = self.codexRenameThread
            Task {
                do {
                    try await codexRenameThread(session, typed)
                    await MainActor.run { self.storeTitles[id] = typed }
                } catch {
                    await self.renameFailed(id, to: typed, notify: sender,
                                            reason: "codex app-server didn't rename it: \(error.localizedDescription)")
                }
            }
            return "Renaming \(label) in Codex."
        }
    }

    /// An Accord `kind:"rename"` delivery: never typed as a prompt; routed through the same
    /// rename path, and the requester hears a refusal or a later failure back.
    func renameDelivery(tile: String, title: String, sender: String, deliveryId: String) -> Bool {
        do { _ = try rename(tile, to: title, by: sender); return true }
        catch {
            Task { await self.renameFailed(tile, to: title, notify: sender, reason: error.localizedDescription) }
            return false
        }
    }

    /// Tell the Accord requester a rename didn't land (refusal, expiry, a failed mechanism).
    private func renameFailed(_ tile: String, to name: String, notify sender: String?, reason: String) async {
        guard let sender else { return }
        let title = info(tile)?.title ?? tile
        _ = try? await accord.request("send", args: ["key": UUID().uuidString, "to": sender,
                                                     "text": "Couldn't rename \(title): \(reason)", "kind": "notification"])
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

    @ObservationIgnored private var openedShared: [String:AgentAppSession] = [:]
    public func openSharedSession(_ session: AgentAppSession) {
        Task {
            let loaded = (try? await accord.history(session)) ?? session
            openedShared[loaded.id] = loaded
            accord.retainedSessionIDs.insert(loaded.id)
            agents.setExternal(Array(openedShared.values),source:"accord-search")
            for _ in 0..<40 {
                if exists(loaded.id) { open(loaded.id,inApp:false); return }
                try? await Task.sleep(nanoseconds:50_000_000)
            }
        }
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

    /// What tile `id` shows, as text: a terminal's last `lines` of screen, a conversation's last
    /// `lines` messages, a page's address. nil where there is nothing to read.
    public func shownText(_ id: String, lines: Int) -> String? {
        if let t = terminals[id] { return t.terminal.screenTail(lines).joined(separator: "\n") }
        if let url = browsers[id]?.info.url, !url.isEmpty { return url }
        return agents.session(id)?.snapshot.items.suffix(lines).map(\.text).joined(separator: "\n")
    }

    /// What each tile shows: a terminal's screen, a conversation's latest messages, a page's address.
    private func readShownText() -> [String: String] {
        var text: [String: String] = [:]
        for (id, session) in terminals { text[id] = shownText(id, lines: session.terminal.rows) }
        for (id, page) in browsers { text[id] = page.info.url }
        for id in order where id.contains(":") { text[id] = shownText(id, lines: 20) }
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

    /// Opens a tile: zoomed open on the board, or, for a Claude, Codex, or Enntity ZCode conversation whose app is
    /// installed, straight in that app, placed at `rect` (AppKit screen coordinates). `inApp: false`
    /// keeps such a conversation in Tessera, as its transcript. An id not on the board opens nothing.
    public func open(_ id: String, inApp: Bool = true, nativeAt rect: CGRect? = nil) {
        guard exists(id) else { return }
        // A LLooM job opens the conversation of the agent reporting it, when that is on the board.
        if inApp, let conversation = linkedConversation(id) {
            agentAcknowledged[id] = Date()
            return open(conversation, inApp: true, nativeAt: rect)
        }
        opened.note(id)
        recentlyUsed.removeAll { $0 == id }; recentlyUsed.insert(id,at:0)
        recentlyUsed = Array(recentlyUsed.prefix(200))
        Preferences.store.set(recentlyUsed,forKey:"tessera.recentTasks")
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

    /// Takes a docked tile out of the dock and opens it full size (a Claude, Codex, or
    /// Enntity ZCode conversation: its transcript).
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
        desk.seen(id)
    }

    /// Whether the terminal itself sits at a question — what typing an answer would hit. A tile
    /// asking only through a linked child (a desk card, an app conversation) doesn't count.
    public func terminalAsking(_ id: String) -> Bool { terminals[id]?.info.activity == .needsInput }

    /// Takes a tile out of what needs the user without answering it (Mark as Seen, Dismiss): its
    /// result counts as seen, its question as set aside until the next one. A question one of
    /// its linked sessions asks is set aside with it.
    public func dismiss(_ id: String) {
        acknowledge(id)
        desk.setAside(id)
        terminals[id]?.dismissQuestion()
        if agents.sessions[id] != nil { agentDismissed[id] = Date() }
        for child in relatedSessions(id) where agentInfo(child).activity == .needsInput {
            dismiss(child.id)
        }
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

    /// Claude, Codex, and Enntity ZCode conversations open straight in their app; Tessera's transcript panel is only
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

    /// Opens or focuses an installed desktop app when its contract has no new-session link.
    public func openApplication(_ app: AgentApp, at rect: CGRect? = nil) {
        WindowPlacer.open(nil, bundleID: app.bundleID, placeAt: placeNativeWindows ? rect : nil)
    }

    public func appForFocus(_ id: String) -> AgentApp? {
        guard let session = agents.session(id), let app = AgentApp(flavor: session.flavor), installedApps.contains(app) else { return nil }
        return app
    }

    // MARK: New app conversations

    /// A conversation just started in a desktop app: when its tile appears, it joins the tab it was
    /// started from and is selected.
    @ObservationIgnored private var pendingAppConversation: (app: AgentApp, since: Date, tab: String?)?

    /// Starts a new conversation in the Claude, Codex, or Enntity ZCode app (in `folder`, with `prompt` placed in its
    /// composer), placing the app window at `rect` (AppKit screen coordinates) when allowed.
    public func newAppConversation(_ app: AgentApp, folder: String?, prompt: String? = nil, placeAt rect: CGRect? = nil) {
        guard app.canCreateConversation, let url = app.newConversationURL(folder: folder, prompt: prompt) else {
            openApplication(app, at: rect)
            return
        }
        pendingAppConversation = (app, Date(), tabForNewTiles())
        if let folder { noteDirectory(folder) }
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

    // MARK: Agent sessions

    // MARK: DeepSeek Harness

    /// The dsh web UI is one shared page, shown inside the panel for the session it last selected.
    public private(set) var dshPage: BrowserSession?
    public private(set) var dshSession: String?

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

    /// The local dsh web UI has no session URL; select its exact visible title within the workspace.
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
        return TileInfo(id: a.id, kind: .agentSession, flavor: a.flavor, title: a.title,
                        subtitle: a.cwd.abbreviatingHome, activity: activity,
                        attention: unseen,
                        lastActivityAt: a.lastActivityAt, detail: detail, progress: a.progress)
    }

    private func fleetChanged() {
        agents.setExternal(fleet.items(lookback: agents.lookback).filter { fleet.showJobs || $0.wantsUser }.map(FleetService.session), source: "fleet")
    }

    func deskChanged() {
        agents.setExternal(desk.sessions, source: "desk")
        pumpWakes()
    }

    // MARK: Waking idle agents

    @ObservationIgnored private var wakeTimer: Timer?
    @ObservationIgnored private var pumpingWakes = false
    @ObservationIgnored private var wakeAgain = false
    /// When each tile last had a queued message typed into it — typing is asynchronous (the
    /// Return lands a beat after the paste), so a fresh wake holds the next message back
    /// until the tile has had time to take it.
    @ObservationIgnored private var wokeAt: [String: Date] = [:]

    /// A tile can take a queued message when it runs an agent (never a bare shell), is running and
    /// not suspended, has the agent in its foreground (a freshly opened tile's shell may sit at a
    /// prompt first, and a message typed there would be a command once the agent exits), sits at an
    /// idle or finished prompt — not working, asking, starting or ended — hasn't had a queued
    /// message typed into it in the last 10 seconds, and the user hasn't typed into it in the last
    /// 20 seconds.
    nonisolated static func canWake(activity: TileActivity, isAgent: Bool, agentInForeground: Bool,
                      running: Bool, suspended: Bool,
                      lastUserInputAt: Date?, lastWokeAt: Date? = nil, now: Date = Date()) -> Bool {
        guard isAgent, agentInForeground, running, !suspended, [.idle, .done].contains(activity) else { return false }
        if let lastWokeAt, now.timeIntervalSince(lastWokeAt) < 10 { return false }
        return lastUserInputAt.map { now.timeIntervalSince($0) >= 20 } ?? true
    }

    #if DEBUG
    /// Test seam: overrides `isWakeableTerminal`.
    @ObservationIgnored var isWakeableTerminalOverride: ((String) -> Bool)?
    /// Test seam: overrides `tileHolds` so close rules can be tested without a fleet board.
    @ObservationIgnored var tileHoldsOverride: ((String) -> [TileHold])?
    #endif

    /// The tile is a terminal running an agent conversation — the only thing a message may be
    /// typed into.
    public func isWakeableTerminal(_ id: String) -> Bool {
        #if DEBUG
        if let isWakeableTerminalOverride { return isWakeableTerminalOverride(id) }
        #endif
        return terminals[id]?.command.flatMap(SessionResume.conversationTool(for:)) != nil
    }

    /// Types queued wake messages into tiles that are ready for them: first in, first out per
    /// tile, one each pass — after typing, the tile goes to work and its next waits for idle.
    /// A tile that's gone fails its queue, so the user is told to check. Re-entrant calls
    /// (the desk's own changed() fires mid-delivery) mark the pass to run once more instead.
    func pumpWakes() {
        if pumpingWakes { wakeAgain = true; return }
        pumpingWakes = true
        defer { pumpingWakes = false }
        desk.expireQueued()
        repeat {
            wakeAgain = false
            for tile in desk.queuedTiles {
                guard let t = terminals[tile] else { desk.failQueued(tile); continue }
                guard Self.canWake(activity: t.info.activity, isAgent: isWakeableTerminal(tile),
                                   agentInForeground: t.runsForegroundProgram, running: t.isRunning,
                                   suspended: t.isSuspended, lastUserInputAt: t.lastUserInputAt,
                                   lastWokeAt: wokeAt[tile]) else { continue }
                if desk.deliverQueued(tile) { wokeAt[tile] = Date() }
            }
        } while wakeAgain
        // While anything is queued a slow pump catches a tile going idle between observations.
        if desk.queuedTiles.isEmpty {
            wakeTimer?.invalidate()
            wakeTimer = nil
        } else if wakeTimer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pumpWakes() }
            }
            wakeTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    /// The tile an Accord address speaks from on this board, if any: a tile's own session, or the
    /// terminal or app conversation its `nativeSession` binding names (the overseer's reports
    /// claude/<its session id>). Falls back to the tile whose session that address reports.
    func tileForSender(_ address: String) -> String? {
        guard let ref = accord.senderTiles[address]
                ?? accord.tileRecords.first(where: { $0.value.address == address })?.key else { return nil }
        if exists(ref) { return ref }
        guard let colon = ref.firstIndex(of: ":") else { return nil }
        let external = String(ref[ref.index(after: colon)...])
        if let tile = terminals.first(where: { $0.value.sessionId == external })?.key { return tile }
        return agents.sessions[ref] != nil ? ref : nil
    }

    /// Who a message's sender is on this board: the overseer tile, another tile, or unplaced.
    func wakeKind(forTile tile: String?) -> WakePolicy.SenderKind {
        tile == nil ? .other : tile == overseerId ? .overseer : .peer
    }

    /// What becomes of a message asking for a tile's prompt: an app conversation is offered to
    /// open with the text copied, a terminal agent is queued for typing or asks first, anything
    /// else keeps the message in Accord only.
    private func wakeRoute(for tile: String, kind: WakePolicy.SenderKind, wantsTyping: Bool) -> AgentDesk.Route {
        guard wantsTyping else { return .inbox }
        if opensInApp(tile) { return .open }
        guard isWakeableTerminal(tile) else { return .inbox }
        return desk.wakePolicy.allows(kind, tileOptedOut: desk.noWake.contains(tile)) ? .queued : .ask
    }

    /// A message from one tile to another (`send_to_tile`): the same routes an Accord delivery
    /// takes. Says what became of it in one line.
    @discardableResult
    func sendToTile(_ tile: String, text: String, from senderTile: String?, label: String) throws -> String {
        guard senderTile != tile else { throw AgentTools.Refusal("A tile can't send a message to itself.") }
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        guard !text.isEmpty else { throw AgentTools.Refusal("Nothing to send: the message is empty.") }
        guard let info = info(tile) else { throw AgentTools.Refusal("No such tile.") }
        let kind = wakeKind(forTile: senderTile)
        let id = "local:" + UUID().uuidString
        let route = wakeRoute(for: tile, kind: kind, wantsTyping: true)
        guard route != .inbox else {
            throw AgentTools.Refusal("\(info.title) isn't an agent in a terminal or an app conversation; it can't be woken with a prompt.")
        }
        guard desk.importMessage(id: id, text: text, from: label, address: nil, tile: senderTile, to: tile, title: info.title, route: route) else {
            throw AgentTools.Refusal("Couldn't record the delivery.")
        }
        switch route {
        case .open: return "Shown to the developer to open \(info.title) with it on the pasteboard."
        case .ask: return "Waiting for the developer's OK to type it into \(info.title)."
        default: return "Will be typed when \(info.title) is idle at its prompt."
        }
    }

    // MARK: Closing tiles

    /// Whether an agent may close a tile outright, only with the developer's OK, or never.
    enum CloseCheck: Equatable {
        case ok, busy(String), never(String)
    }

    /// A reservation the tile's Accord session (or its observation) holds on shared hardware.
    public struct TileHold: Equatable, Sendable {
        public var resource: String
        public var reservation: String
        public var until: Date?
        public init(resource: String, reservation: String, until: Date?) {
            self.resource = resource
            self.reservation = reservation
            self.until = until
        }
    }

    /// The close rules, shared by the tool and the CLI: the overseer's own tile is never
    /// closed; a desk card dismisses; an idle shell or agent closes; a tile that is working,
    /// asking, starting, being typed into, holding a non-agent program in its foreground, or
    /// holding a shared reservation asks first.
    nonisolated static func closeCheck(isOverseer: Bool, isDeskCard: Bool, isTerminal: Bool, activity: TileActivity,
                           running: Bool, suspended: Bool, isAgent: Bool, foregroundProgram: Bool,
                           lastUserInputAt: Date?, holds: [TileHold] = [], now: Date = Date()) -> CloseCheck {
        if isOverseer { return .never("the overseer's own tile") }
        if isDeskCard { return .ok }
        if isTerminal && (!running || suspended) { return .ok }
        switch activity {
        case .working: return .busy("working")
        case .needsInput: return .busy("asking")
        case .starting: return .busy("starting")
        default: break
        }
        if isTerminal {
            if let lastUserInputAt, now.timeIntervalSince(lastUserInputAt) < 20 { return .busy("being typed into") }
            if !isAgent && foregroundProgram { return .busy("running a program other than its shell") }
        }
        if !holds.isEmpty {
            return .busy("holds " + holds.map { "\($0.resource) (reservation \($0.reservation))" }.joined(separator: ", "))
        }
        return .ok
    }

    /// `close_tile` and `tessera close`: closes like the developer's own Close (toast, Undo) or
    /// dismisses a desk card. A busy tile is refused unless `force`, which asks the developer on
    /// a desk card first. Every outcome is logged with who asked.
    @discardableResult
    func closeTile(_ id: String, force: Bool, from senderTile: String?, label: String) throws -> String {
        // A desk card isn't a tile: closing it dismisses the question or request it carries.
        if id.hasPrefix(AgentDesk.idPrefix) {
            guard let card = desk.sessions.first(where: { $0.id == id }) else { throw AgentTools.Refusal("No such tile.") }
            desk.setAside(id)
            CloseLog.append(in: directory, tile: id, title: card.title, kind: "desk",
                            by: senderTile.map { "\(label) (tile \($0))" } ?? label, outcome: "closed", force: force)
            return "Dismissed \(card.title)."
        }
        guard let info = info(id) else { throw AgentTools.Refusal("No such tile.") }
        let t = terminals[id]
        let check = Self.closeCheck(isOverseer: id == overseerId, isDeskCard: id.hasPrefix(AgentDesk.idPrefix),
                                  isTerminal: t != nil, activity: info.activity, running: t?.isRunning ?? false,
                                  suspended: t?.isSuspended ?? false, isAgent: t != nil && isWakeableTerminal(id),
                                  foregroundProgram: t?.runsForegroundProgram ?? false, lastUserInputAt: t?.lastUserInputAt,
                                  holds: tileHolds(id))
        let by = senderTile.map { "\(label) (tile \($0))" } ?? label
        func log(_ outcome: String, reason: String? = nil) {
            CloseLog.append(in: directory, tile: id, title: info.title, kind: info.kind.rawValue,
                            by: by, outcome: outcome, reason: reason, force: force)
        }
        switch check {
        case .never:
            log("refused", reason: "the overseer's own tile")
            throw AgentTools.Refusal("Tessera never closes the overseer's own tile.")
        case .busy(let reason) where !force:
            log("refused", reason: reason)
            throw AgentTools.Refusal("\(info.title) is \(reason), so it wasn't closed. Pass force to ask the developer.")
        case .busy(let reason):
            desk.requestClose(from: by, fromTile: senderTile, tile: id, title: info.title, reason: reason)
            log("asked", reason: reason)
            return "Waiting for the developer's OK to close \(info.title) (it's \(reason))."
        case .ok:
            if let onAgentClose { onAgentClose(id, by) } else { close(id, by: by) }
            guard !exists(id) else { throw AgentTools.Refusal("Couldn't close \(info.title).") }
            return "\(info.kind.closedLabel) \(info.title)."
        }
    }

    /// Tiles that still exist on the board, hidden conversations and the overseer included: a
    /// close that only hides a tile keeps its Accord observation live.
    var presentTileIDs: Set<String> { Set(order).union(hiddenAgents.keys).union(overseerId.map { [$0] } ?? []) }

    /// The shared reservations a tile's agent — or the observation that stands for it — holds,
    /// by the fleet board Accord projects. An unavailable board yields none: close works as it
    /// did before reservations were visible.
    func tileHolds(_ id: String) -> [TileHold] {
        #if DEBUG
        if let tileHoldsOverride { return tileHoldsOverride(id) }
        #endif
        var addresses = Set(accord.senderTiles.filter { $0.value == id }.keys)
        if let record = accord.tileRecords[id] { addresses.insert(record.address) }
        return Self.tileHolds(fleet.board, addresses: addresses)
    }

    /// Held reservations on the fleet board whose holder is one of `addresses`: only claims the
    /// resource lists as held count — queued requests are not holds.
    nonisolated static func tileHolds(_ board: LLoomSchedule.Board?, addresses: Set<String>) -> [TileHold] {
        guard let board else { return [] }
        let heldIds = Set(board.resources.flatMap { $0.holders ?? [] })
        let labels = Dictionary(board.resources.map { ($0.id, $0.label ?? $0.id) }, uniquingKeysWith: { a, _ in a })
        return board.reservations.compactMap { lease in
            guard heldIds.contains(lease.id), let session = lease.session else { return nil }
            let address = session.hasPrefix("accord:") ? String(session.dropFirst(7)) : session
            guard addresses.contains(address) else { return nil }
            return TileHold(resource: labels[lease.resource] ?? lease.resource, reservation: lease.id,
                            until: lease.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) })
        }
    }

    /// The warning the developer sees before closing tiles whose agents hold shared hardware:
    /// which tiles hold what until when, and that Accord releases it after the orphan grace.
    /// Nil when no named tile holds anything.
    nonisolated static func closeWarning(_ tiles: [(title: String, holds: [TileHold])]) -> String? {
        let holding = tiles.filter { !$0.holds.isEmpty }
        guard !holding.isEmpty else { return nil }
        func clause(_ hold: TileHold) -> String {
            hold.until.map { "\(hold.resource) until \(Self.holdTime($0))" } ?? "\(hold.resource) with no deadline"
        }
        let parts = holding.map { "\($0.title) holds " + $0.holds.map(clause).joined(separator: " and ") }
        var seen = Set<String>(), resources: [String] = []
        for hold in holding.flatMap(\.holds) where seen.insert(hold.resource).inserted { resources.append(hold.resource) }
        return parts.joined(separator: "; ") + ". Closing ends \(holding.count == 1 ? "this agent" : "these agents"). "
            + "Accord releases \(resources.joined(separator: " and ")) 15 minutes later unless the agent comes back."
    }

    /// The warning text before the developer's own close of tiles that hold reservations; nil
    /// when nothing held is in the way and close proceeds as today.
    public func closeWarning(for ids: [String]) -> String? {
        Self.closeWarning(ids.compactMap { id in info(id).map { (title: $0.title, holds: tileHolds(id)) } })
    }

    /// A hold's end as the developer reads it.
    nonisolated static func holdTime(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }

    /// The developer's answer to a close request: approve closes the tile through the same path,
    /// keeping the card's asker as the one who asked.
    private func answerClose(_ request: AgentDesk.CloseRequest, approved: Bool) {
        CloseLog.append(in: directory, tile: request.tile, title: request.title,
                        kind: info(request.tile)?.kind.rawValue ?? "gone",
                        by: request.from, outcome: approved ? "approved" : "declined", reason: request.reason, force: true)
        guard approved, exists(request.tile) else { return }
        let by = "\(request.from) (approved by the developer)"
        if let onAgentClose { onAgentClose(request.tile, by) } else { close(request.tile, by: by) }
    }

    // MARK: Opening tiles

    /// How many opens and reopens one caller gets per rolling hour (Settings → Agents).
    public static var agentOpensPerHour: Int {
        let set = Preferences.store.integer(forKey: "tessera.agentOpensPerHour")
        return max(1, set == 0 ? 10 : set)
    }

    /// When each caller opened something lately, keyed by tile id or by label — the rolling
    /// window for `agentOpensPerHour`; a restart resets it.
    @ObservationIgnored private var opensByCaller: [String: [Date]] = [:]

    #if DEBUG
    /// Test seams: overrides the installed-agent set, and how long `openTile` waits for the
    /// tile's Accord address.
    @ObservationIgnored var openTileAgentsOverride: Set<String>?
    @ObservationIgnored var accordAddressWait: TimeInterval = 10
    #endif

    /// Which agents `open_tile` may start, to their preset commands.
    private static let openable: [String: String?] = ["shell": nil, "claude": "claude", "codex": "codex",
                                                    "devin": "devin", "omp": "omp"]

    /// `open_tile` and `tessera open`: starts a tile like the developer's New (or brings back a
    /// closed one like Reopen), without disturbing the board the developer is looking at. The
    /// reply gives the tile id and, when Accord has caught up, the tile's address.
    @discardableResult
    func openTile(agent: String?, cwd: String?, title: String?, prompt: String?, resume: String?,
                  reopen: String?, from senderTile: String?, label: String) async throws -> String {
        let by = senderTile.map { "\(label) (tile \($0))" } ?? label
        func refuse(_ message: String, title: String? = nil, agent: String? = nil, cwd: String? = nil,
                    resume: String? = nil, prompt: String? = nil) throws -> Never {
            OpenLog.append(in: directory, title: title ?? agent ?? reopen ?? "tile", agent: agent ?? "tile", cwd: cwd,
                           by: by, outcome: "refused", reason: message, resume: resume, prompt: prompt)
            throw AgentTools.Refusal(message)
        }
        let caller = senderTile ?? label
        let cutoff = Date().addingTimeInterval(-3600)
        opensByCaller[caller] = (opensByCaller[caller] ?? []).filter { $0 > cutoff }
        func takeSlot() throws {
            guard (opensByCaller[caller] ?? []).count < Self.agentOpensPerHour else {
                try refuse("\(label) has opened \(Self.agentOpensPerHour) tiles in the last hour (limit \(Self.agentOpensPerHour), Settings → Agents).")
            }
            opensByCaller[caller, default: []].append(Date())
        }

        if let reopen {
            guard agent == nil, cwd == nil, title == nil, prompt == nil, resume == nil else {
                try refuse("Reopen takes no other parameters.", title: reopen)
            }
            guard recentlyClosed.tiles.contains(where: { $0.id == reopen }) || hiddenAgents[reopen] != nil else {
                try refuse("Not in Recently closed: \(reopen).", title: reopen)
            }
            try takeSlot()
            guard self.reopen(reopen, quietly: true) else { try refuse("Couldn't reopen \(reopen).", title: reopen) }
            let name = info(reopen)?.title ?? reopen
            OpenLog.append(in: directory, tile: reopen, title: name, agent: "reopen", by: by, outcome: "reopened")
            return "Reopened \(name) as tile \(reopen)."
        }

        let agentName = (agent ?? "").lowercased()
        guard let preset = Self.openable[agentName] else {
            try refuse("Only shell, claude, codex, devin or omp can be opened.", title: title, agent: agent)
        }
        guard agentName == "shell" || installedAgents.contains(agentName) else {
            try refuse("\(agentName) isn't installed on this Mac's PATH.", title: title, agent: agentName)
        }
        guard agentName != "shell" || (prompt == nil && resume == nil) else {
            try refuse("prompt and resume need an agent, not a shell.", title: title, agent: agentName)
        }
        var command = preset
        if let resume {
            guard SessionResume.isSafeId(resume) else {
                try refuse("Not a session id: \(resume).", title: title, agent: agentName, resume: resume)
            }
            if let holding = order.first(where: { terminals[$0]?.sessionId == resume }) {
                try refuse("That conversation is already open in tile \(holding).", title: title, agent: agentName, resume: resume)
            }
            guard let resumed = SessionResume.resumeCommand(original: preset!, sessionId: resume) else {
                try refuse("\(agentName) can't resume \(resume).", title: title, agent: agentName, resume: resume)
            }
            command = resumed
        }
        guard let raw = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            try refuse("Give a working directory.", title: title, agent: agentName)
        }
        let path = (raw as NSString).expandingTildeInPath.standardizedPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            try refuse("Not a directory: \(path).", title: title, agent: agentName, cwd: path)
        }
        let name = title.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)) }
        try takeSlot()
        let id = launch(command: command, cwd: path, title: name?.isEmpty == false ? name : nil,
                        quietly: true, tab: senderTile.flatMap { groups.group(of: $0)?.id }, after: senderTile)
        var outcome: String?
        if let prompt, !prompt.isEmpty {
            do { outcome = try sendToTile(id, text: prompt, from: senderTile, label: label) }
            catch { outcome = "The prompt wasn't sent: \(error.localizedDescription)" }
        }
        OpenLog.append(in: directory, tile: id, title: name ?? agentName, agent: agentName, cwd: path,
                       by: by, outcome: "opened", resume: resume, prompt: prompt)
        var reply = "Opened \(info(id)?.title ?? agentName) as tile \(id) (\(agentName) in \(path.abbreviatingHome))."
        if let address = await accordAddress(for: id) { reply += " Accord: \(address)." }
        else { reply += " Accord address not reported yet; it appears on board within a few seconds." }
        if let outcome { reply += "\n" + outcome }
        return reply
    }

    /// Which agent names `open_tile` accepts as installed — the detected presets, overridable in tests.
    private var installedAgents: Set<String> {
        #if DEBUG
        if let openTileAgentsOverride { return openTileAgentsOverride }
        #endif
        return Set(presets.compactMap(\.command))
    }

    /// The tile's Accord address once Accord reports it, else nil after a short wait.
    private func accordAddress(for id: String) async -> String? {
        #if DEBUG
        let wait = accordAddressWait
        #else
        let wait: TimeInterval = 10
        #endif
        await accord.refresh()
        for _ in 0..<max(1, Int(wait * 2)) {
            if let address = accord.tileRecords[id]?.address { return address }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return accord.tileRecords[id]?.address
    }

    /// Canonical native identities, including Claude desktop's distinct CLI session ID.
    public var nativeSessionAliases: Set<String> {
        var ids=Set(order.filter { !$0.hasPrefix("accord:") })
        for t in terminals.values where [.codex,.claude].contains(t.info.flavor) { if let id=t.sessionId { ids.insert((t.info.flavor == .codex ? "codex:" : "claude:")+id) } }
        for a in agents.sessions.values.map(\.session) where a.flavor != .accord {
            if let command=a.resumeCommand {
                let words=command.split(separator:" ").map(String.init)
                if let i=words.firstIndex(where: { $0 == "--resume" || $0 == "resume" }), i+1<words.count, SessionResume.isSafeId(words[i+1]) {
                    ids.insert((words.first == "codex" ? "codex:" : "claude:")+words[i+1])
                }
            }
        }
        return ids
    }
    /// MRU follows deliberate opens, not tool traffic. Arrival times seed unopened tasks once.
    nonisolated static func taskOrder(_ ids: [String], recent: [String], activity: [String:Date]) -> [String] {
        let ranks=Dictionary(recent.enumerated().map { ($0.element,$0.offset) },uniquingKeysWith: { a,_ in a })
        let positions=Dictionary(ids.enumerated().map { ($0.element,$0.offset) },uniquingKeysWith: { a,_ in a })
        return ids.sorted { a,b in
            let ar=ranks[a] ?? Int.max, br=ranks[b] ?? Int.max
            if ar != br { return ar < br }
            let at=activity[a] ?? .distantPast, bt=activity[b] ?? .distantPast
            return at == bt ? positions[a]! < positions[b]! : at > bt
        }
    }
    public func relatedSessions(_ id: String) -> [AgentAppSession] {
        order.compactMap { agents.session($0) }.filter { linkedConversation($0.id) == id }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// The board as the steward reads it: every tile with what it shows.
    private func stewardDigests() -> [Steward.Digest] {
        let now = Date()
        return allTiles.filter { $0.flavor != .agentDesk }.map { tile in
            let text: String
            if let t = terminals[tile.id] {
                text = t.terminal.screenTail(t.terminal.rows).joined(separator: "\n").trimmingCharacters(in: .newlines)
            } else if let a = agents.session(tile.id) {
                text = a.snapshot.items.suffix(8).map { "\($0.role.rawValue): \($0.text.preview(400))" }.joined(separator: "\n")
            } else {
                text = tile.url ?? ""
            }
            return Steward.Digest(tile, text: text, unseen: tile.isUnseen, now: now)
        }
    }

    /// Types an agent's message into a terminal tile as a paste, then presses Return, the way the
    /// user would. False when the tile isn't a running terminal — and a bare shell is never
    /// typed into, whoever asked.
    func typeMessage(_ text: String, into id: String) -> Bool {
        guard let t = terminals[id], t.isRunning, isWakeableTerminal(id) else { return false }
        let bracketed = t.terminal.bracketedPasteMode
        t.send(Array(((bracketed ? "\u{1b}[200~" : "") + text + (bracketed ? "\u{1b}[201~" : "")).utf8))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { t.send([13]) }
        return true
    }

    /// The tile of the conversation a LLooM job or lease names (`claude:<id>`, `codex:<id>`): by its
    /// tile id, else by the session id a terminal or a Claude app conversation carries.
    public func linkedConversation(_ id: String) -> String? {
        // A desk card is about a tile, not its child: it stands in the lane as its own row
        // (with its own choices), and the tile it names doesn't borrow the card's asking state.
        guard let session = agents.session(id), session.flavor != .agentDesk, let link = session.link else { return nil }
        if link != id, exists(link), agents.session(link)?.flavor != .lloom, agents.session(link)?.link == nil { return link }
        guard let colon = link.firstIndex(of: ":") else { return nil }
        let sessionId = String(link[link.index(after: colon)...])
        guard SessionResume.isSafeId(sessionId) else { return nil }
        let candidates = [link] + terminals.filter { $0.value.sessionId == sessionId }.map(\.key)
            + agents.sessions.filter { $0.value.session.resumeCommand?.split(separator: " ").contains(Substring(sessionId)) == true }.map(\.key)
        return candidates.first { $0 != id && exists($0) && agents.session($0)?.flavor != .lloom }
    }

    private func syncAgents() {
        let live = agents.sessions
        // Sources arrive independently: a later Accord discovery is still historical if its
        // last result predates this launch. New results after launch remain unseen.
        for id in live.keys where agentAcknowledged[id] == nil { agentAcknowledged[id] = attentionBaseline }
        let newest = live.values.map(\.session).sorted { $0.lastActivityAt > $1.lastActivityAt }
        var added: [AgentAppSession] = []
        for a in newest where !order.contains(a.id) {
            if let hidden = hiddenAgents[a.id] {
                if a.lastActivityAt <= hidden { continue }
                // Active again, it is back by itself: there is nothing left to undo.
                hiddenAgents[a.id] = nil
                _ = recentlyClosed.take(a.id)
            }
            arrivalActivity[a.id] = a.lastActivityAt
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

    func agentsChanged() {
        syncAgents()
        if usage.codexRateLimits != agents.codexRateLimits { usage.codexRateLimits = agents.codexRateLimits }
    }

    func adopt(_ session: TerminalSession) {
        session.onResumableChange = { [weak self] in self?.save() }
        session.onOpenLink = { [weak self] url in self?.onLink?(url) }
        terminals[session.id] = session
        arrivalActivity[session.id] = session.info.lastActivityAt
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
            SessionBinding.unambiguous(waiting.filter { $0.command.flatMap(SessionResume.conversationTool(for:)) == tool }
                .map { SessionBinding.Candidate(tileId: $0.id, cwd: $0.cwd, launchedAt: $0.launchedAt,
                                                continuing: $0.command.map(SessionResume.continuesLatest) ?? false) })
                // After ten minutes unbound it rarely happens, so those are looked for once a minute.
                .filter { now.timeIntervalSince($0.launchedAt) < 600 || bindPasses % 12 == 0 }
        }
        let codex = candidates(.codex), claude = candidates(.claude)
        // Devin's session locks name the session its foreground `devin acp` belongs to, so a tile
        // running one binds exactly — no folder or time to match on, and nothing to guess.
        let devin = terminals.values.compactMap { t -> (tileId: String, pgid: pid_t)? in
            guard t.isRunning, !t.isSuspended, t.command.flatMap(SessionResume.conversationTool(for:)) == .devin,
                  let pgid = t.foregroundProcessGroup else { return nil }
            return (t.id, pgid)
        }
        guard !codex.isEmpty || !claude.isEmpty || !devin.isEmpty else { return }
        let claimed = Set(terminals.values.compactMap(\.sessionId))
        binding = true
        DispatchQueue.global(qos: .utility).async {
            var found = codex.isEmpty ? [:] : CodexRollouts.bind(codex, claimed: claimed)
            if !claude.isEmpty { found.merge(ClaudeSessions.bind(claude, claimed: claimed.union(found.values))) { a, _ in a } }
            var devinFound: [String: String] = [:]
            var held = claimed
            for (tileId, pgid) in devin {
                guard let id = DevinSessions.session(forProcessGroup: pgid), !held.contains(id) else { continue }
                devinFound[tileId] = id
                held.insert(id)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.binding = false
                    self.readOriginTitles()
                    var changed = false
                    for (tile, session) in found {
                        self.terminals[tile]?.bind(sessionId: session)
                        changed = true
                    }
                    // The lock says which session this tile's Devin is in now, even replacing one
                    // the command line had named (the REPL may have moved between sessions).
                    for (tile, session) in devinFound where self.terminals[tile]?.sessionId != session {
                        self.terminals[tile]?.bind(sessionId: session, replacing: true)
                        changed = true
                    }
                    if changed { self.save() }
                }
            }
        }
    }

    /// Every bound agent terminal's origin title, read off the main thread on the binder's cadence.
    /// A failed read keeps the last good title.
    private func refreshOriginTitles() {
        guard !binding else { return }
        let bound = terminals.values.compactMap { t -> (String, SessionResume.Tool, String)? in
            guard let id = t.sessionId, let tool = t.command.flatMap(SessionResume.conversationTool(for:)),
                  [.claude, .codex, .devin].contains(tool) else { return nil }
            return (t.id, tool, id)
        }
        guard !bound.isEmpty else { return }
        binding = true
        DispatchQueue.global(qos: .utility).async {
            let titles: [String: String] = bound.reduce(into: [:]) { out, entry in
                let (tile, tool, session) = entry
                switch tool {
                case .claude: out[tile] = OriginTitles.claude(session)
                case .codex: out[tile] = OriginTitles.codex(session)
                case .devin: out[tile] = OriginTitles.devin(session)
                default: break
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self.binding = false
                for (tile, name) in titles where self.storeTitles[tile] != name { self.storeTitles[tile] = name }
            } }
        }
    }

    /// The Codex thread whose name was just set may not have flushed to the index yet.
    private func readOriginTitles() {
        let bound = terminals.values.compactMap { t -> (String, SessionResume.Tool, String)? in
            guard let id = t.sessionId, let tool = t.command.flatMap(SessionResume.conversationTool(for:)) else { return nil }
            return (t.id, tool, id)
        }
        for (tile, tool, session) in bound {
            let name = tool == .claude ? OriginTitles.claude(session)
                : tool == .codex ? OriginTitles.codex(session)
                : tool == .devin ? OriginTitles.devin(session) : nil
            if let name, storeTitles[tile] != name { storeTitles[tile] = name }
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
        StateFile.save(Saved(tiles: tiles.map(Lossy.init), defaultDirectory: defaultDirectory, placeNativeWindows: placeNativeWindows,
                             groups: groups.list, resumeOnLaunch: resumeOnLaunch, order: savedOrder, hidden: hiddenAgents,
                             agentLookbackHours: agents.lookback / 3600, titles: [:],
                             closed: recentlyClosed.tiles.map(Lossy.init), dock: dock.ids,
                             dockWidth: dockWidth.map(Double.init), overseer: overseerId), to: saveURL)
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
                         sessionId: t.sessionId, suspended: t.isSuspended, wasWorking: t.hasLiveWork)
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
            adopt(TerminalSession(id: tile.id, command: tile.command, cwd: cwd,
                                  title: tile.command.flatMap(SessionResume.conversationTool(for:)) == nil ? tile.title : nil, label: tile.command,
                                  sessionId: decision.sessionId, resuming: true, mayContinueLatest: decision.mayContinueLatest,
                                  startSuspended: suspended, resumingWork: tile.wasWorking == true))
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
        placeNativeWindows = saved.placeNativeWindows ?? false
        groups = TileGroups(saved.groups ?? [])
        resumeOnLaunch = saved.resumeOnLaunch ?? true
        savedOrder = saved.order ?? []
        hiddenAgents = saved.hidden ?? [:]
        if let hours = saved.agentLookbackHours, AgentAppWatcher.lookbackHours.contains(hours) { agents.lookback = hours * 3600 }
        recentlyClosed = RecentlyClosed(saved.closed?.compactMap(\.value) ?? [])
        let plan = restorePlan(tiles)
        for tile in tiles where revive(tile, as: plan[tile.id], suspended: tile.suspended == true || !resumeOnLaunch) {
            order.append(tile.id)
        }
        selectedId = order.first
        overseerId = saved.overseer
        // The dock as it was left (a docked app conversation is found again after launch); what is
        // in it is looked at from the start.
        dock = WatchDock((saved.dock ?? []).filter { order.contains($0) || $0.contains(":") })
        dockWidth = saved.dockWidth.map { CGFloat($0) }
        for id in dock.ids { setViewed(id, true) }
        fit(dock.ids)
    }
}
