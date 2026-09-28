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
    public let usage: UsageService
    public let machines: MachineMonitor
    public private(set) var presets: [LaunchPreset] = LaunchCatalog.known

    public var selectedId: String?
    public private(set) var expandedId: String?
    public var filter: Filter = .all
    public private(set) var groups = TileGroups()
    /// Snap the Claude / Codex window onto the tile when an app session is opened.
    public var placeNativeWindows = true
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
        terminals[session.id] = session
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
        WindowPlacer.open(a.openURL, bundleID: a.bundleID, placeAt: placeNativeWindows ? rect : nil)
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
        for a in newest where !order.contains(a.id) {
            if let hidden = hiddenAgents[a.id], a.lastActivityAt <= hidden { continue }
            hiddenAgents[a.id] = nil
            if agentAcknowledged[a.id] == nil { agentAcknowledged[a.id] = .distantPast }
            order.append(a.id)
        }
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

    // MARK: Persistence

    struct Saved: Codable {
        struct Tile: Codable {
            var id: String
            var kind: TileKind
            var command: String?
            var cwd: String?
            var title: String?
            var url: String?
        }
        var tiles: [Tile]
        var defaultDirectory: String?
        var placeNativeWindows: Bool?
        var groups: [TileGroup]?
    }

    private var saveURL: URL { directory.appendingPathComponent("workspace.json") }

    public func save() {
        let tiles: [Saved.Tile] = order.compactMap { id in
            if let t = terminals[id] { return .init(id: id, kind: .terminal, command: t.command, cwd: t.cwd, title: t.customTitle) }
            if let b = browsers[id] { return .init(id: id, kind: .browser, url: b.url?.absoluteString) }
            return nil
        }
        let saved = Saved(tiles: tiles, defaultDirectory: defaultDirectory, placeNativeWindows: placeNativeWindows, groups: groups.list)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: saveURL, options: .atomic) }
    }

    private func restore() {
        guard let data = try? Data(contentsOf: saveURL), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        defaultDirectory = saved.defaultDirectory ?? defaultDirectory
        placeNativeWindows = saved.placeNativeWindows ?? true
        groups = TileGroups(saved.groups ?? [])
        // "Continue the latest conversation" only makes sense for one tile per tool and folder;
        // any others start fresh rather than all attaching to the same session.
        var resumed: Set<String> = []
        for tile in saved.tiles {
            switch tile.kind {
            case .terminal:
                let cwd = tile.cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? defaultDirectory
                var command = tile.command
                if let c = command, resumed.insert(c + "@" + cwd).inserted { command = Self.resumeCommand(c) }
                // Title by what the user launched, not the resume flags added here.
                let s = TerminalSession(id: tile.id, command: command, cwd: cwd, title: tile.title, label: tile.command)
                terminals[s.id] = s
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

    /// Relaunching an agent CLI should pick the conversation back up rather than start blank.
    static func resumeCommand(_ command: String?) -> String? {
        guard let command else { return nil }
        switch command.trimmingCharacters(in: .whitespaces) {
        case "claude": return "claude --continue"
        case "codex": return "codex resume --last"
        default: return command
        }
    }

    static func normalizeURL(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.contains("://") { return URL(string: s) }
        if s.contains(".") && !s.contains(" ") { return URL(string: "https://" + s) }
        var c = URLComponents(string: "https://www.google.com/search")
        c?.queryItems = [URLQueryItem(name: "q", value: s)]
        return c?.url
    }
}
