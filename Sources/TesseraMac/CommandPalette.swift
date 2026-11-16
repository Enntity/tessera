import SwiftUI
import TesseraHost
import TesseraKit

/// ⌘K: find any tile, launch any agent, run any command, open any URL, ask the overseer, or act on
/// the whole board — one field. ⌘N is the same field with only what can be started; either way
/// what starts, starts in the folder at the field's right, which can be picked there or typed.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        let items = model.paletteItems(query)
        ZStack(alignment: .top) {
            Style.scrim
                .onTapGesture { dismiss() }
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: Style.Space.gutter) {
                    Image(systemName: model.paletteMode.symbol).foregroundStyle(Style.dim)
                    TextField(model.paletteMode.prompt, text: $query)
                        .textFieldStyle(.plain)
                        .font(Style.title)
                        .focused($focused)
                        .onSubmit { run(items) }
                    if model.paletteMode != .url { folderMenu }
                }
                .padding(Style.Space.xl)
                if let error = model.workspace.accord.searchError, model.workspace.accord.searchQuery == query.trimmingCharacters(in:.whitespacesAndNewlines) {
                    Text(error).font(Style.caption).foregroundStyle(Style.dim).padding(.horizontal,Style.Space.xl)
                }
                Hairline()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: Style.Space.xxs) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                row(item, selected: i == selection)
                                    .id(i)
                                    .onTapGesture { run(item) }
                            }
                        }
                        .padding(Style.Space.s)
                    }
                    .frame(maxHeight: Style.Metrics.palette.height)
                    .onChange(of: selection) { _, s in proxy.scrollTo(s) }
                }
            }
            .frame(width: Style.Metrics.palette.width)
            .overlaySurface()
            .padding(.top, Style.Metrics.paletteTop)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selection = 0 }
        .task(id:query) {
            try? await Task.sleep(nanoseconds:250_000_000)
            guard !Task.isCancelled, model.paletteMode != .url else { return }
            await model.workspace.accord.search(query)
        }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(items.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: Style.Space.l) {
            Image(systemName: item.symbol)
                .font(Style.ui(.body, .semibold))
                .foregroundStyle(item.color)
                .frame(width: Style.Metrics.control, height: Style.Metrics.control)
                .background(Style.Neutral.hover, in: Style.shape(Style.Radius.s))
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(Style.ui(.body, .medium)).foregroundStyle(Style.ink)
                Text(item.subtitle).font(Style.caption).foregroundStyle(Style.muted).lineLimit(1)
            }
            Spacer()
            if selected { Text("↩").font(Style.caption).foregroundStyle(Style.dim) }
        }
        .padding(.horizontal, Style.Space.gutter)
        .padding(.vertical, Style.Space.s)
        .background(selected ? Style.Neutral.selected : .clear, in: Style.shape(Style.Radius.m))
        .contentShape(Rectangle())
    }

    /// Where what is started next will start: a click picks another folder (as typing a path does).
    private var folderMenu: some View {
        let workspace = model.workspace
        let folder = model.contextDirectory
        return Menu {
            Section("Start in") {
                ForEach(workspace.recentDirectories.filter { $0 != folder }, id: \.self) { dir in
                    Button(dir.abbreviatingHome) { model.launchDirectory = dir }
                }
                Button("Choose Folder…") {
                    if let dir = model.chooseFolder(from: folder) { model.launchDirectory = dir }
                    focused = true
                }
            }
            if folder != workspace.defaultDirectory {
                Button("Make This the Default Folder") {
                    workspace.defaultDirectory = folder
                    workspace.save()
                }
            }
        } label: {
            Label(folder.abbreviatingHome, systemImage: model.launchDirectory == nil ? "folder" : "folder.fill")
                .font(Style.caption).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(model.launchDirectory == nil ? Style.muted : Style.ink)
        .fixedSize()
        .help("New tiles start here. Pick another folder, or type a path (~/…)")
    }

    private func run(_ items: [PaletteItem]) {
        if items.indices.contains(selection) { run(items[selection]) }
    }

    /// A row that only sets up what comes next (a folder to start in) leaves the field open, and empty.
    private func run(_ item: PaletteItem) {
        item.run()
        if item.stays { query = "" } else { dismiss() }
    }

    private func dismiss() {
        model.showPalette = false
        model.paletteMode = .all
    }
}

struct PaletteItem: Identifiable {
    let id: String
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String
    /// The palette stays open after it (see `CommandPalette.run`).
    var stays = false
    let run: () -> Void
}

extension AppModel.PaletteMode {
    var symbol: String {
        switch self {
        case .all: "command"
        case .url: "globe"
        case .new: "plus"
        }
    }

    var prompt: String {
        switch self {
        case .all: "Find a tile, launch, run, ask, or open a URL…"
        case .url: "URL or search"
        case .new: "Start an agent, a command, a URL — or type a folder (~/…)"
        }
    }
}

extension AppModel {
    /// The palette's rows for what has been typed. The tiles it finds come first, best match on
    /// top, so ⏎ jumps there; then what it could start or do, each row saying which. With nothing
    /// typed: what can be started, what waits on the user, and what can be done to the board.
    func paletteItems(_ query: String) -> [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let cwd = contextDirectory
        let folder = cwd.abbreviatingHome
        func matches(_ text: String) -> Bool { q.isEmpty || TileSearch.match(q, in: text) != nil }

        let openURL = PaletteItem(id: "url", symbol: "globe", color: Style.dim, title: "Open \(q)", subtitle: "New web tile") {
            self.create { $0.openBrowser(q) }
        }
        if paletteMode == .url { return q.isEmpty ? [] : [openURL] }

        // Where what is started will start: a typed path's folders, and folders used lately whose
        // name the typing begins (with nothing typed, the launcher lists those last).
        let typedFolders = StartFolders.completions(of: q, isFolder: StartFolders.isFolder)
        let recentFolders = workspace.recentDirectories.filter { dir in
            guard dir != cwd, !typedFolders.contains(dir) else { return false }
            if q.isEmpty { return paletteMode == .new }
            return q.count > 1 && (TileSearch.match(q, in: (dir as NSString).lastPathComponent) ?? 2) < 2
        }
        let folders = (typedFolders + recentFolders).map { dir in
            PaletteItem(id: "folder-\(dir)", symbol: "folder", color: Style.dim, title: "Start in \(dir.abbreviatingHome)",
                        subtitle: dir == cwd ? "Where new tiles start now" : "What you start next opens in this folder", stays: true) {
                self.launchDirectory = dir
            }
        }

        let groups = workspace.groups
        func candidate(_ tile: TileInfo, hidden: Bool = false) -> TileSearch.Candidate {
            TileSearch.Candidate(tile: tile, tab: groups.group(of: tile.id)?.name, hidden: hidden)
        }
        let found = q.isEmpty ? workspace.allTiles.attentionQueue().map { candidate($0) }
            : TileSearch.rank(q, workspace.allTiles.map { candidate($0) } + workspace.hiddenTiles.map { candidate($0, hidden: true) })
        let tiles = found.map { c in
            let tile = c.tile
            let facts = [tile.activity.label, tile.needsUser ? tile.detail : nil, tile.subtitle, c.tab]
            return PaletteItem(id: "tile-\(tile.id)", symbol: c.hidden ? "eye" : "arrow.up.right.square", color: Style.state(tile.activity),
                               title: c.hidden ? "Show \(tile.title)" : tile.title,
                               subtitle: ((c.hidden ? ["Hidden"] : []) + facts.compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: " · ")) {
                c.hidden ? self.reopen([tile.id], open: true) : self.open(tile.id)
            }
        }

        let presets = workspace.presets.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || ($0.command ?? "").hasPrefix(q) }.map { p in
            PaletteItem(id: "preset-\(p.name)", symbol: p.flavor.symbol, color: Style.accent(p.flavor),
                        title: "New \(p.name)", subtitle: "Terminal · " + (p.command ?? "login shell") + " · " + folder) {
                self.create { $0.launch(command: p.command, cwd: cwd) }
            }
        }
        // Desktop agent apps: a blank conversation, or one seeded with what's been typed.
        let seed = q.isEmpty || WebAddress.looksLikeAddress(q) ? nil : q
        let apps = workspace.installedApps.map { app in
            let flavor = app.flavor
            return PaletteItem(id: "app-\(app.rawValue)", symbol: flavor.symbol, color: Style.accent(flavor),
                               title: app.canCreateConversation ? (seed.map { "Ask \(flavor.displayName) app: “\($0.preview(50))”" } ?? app.newLabel) : app.newLabel,
                               subtitle: app.canCreateConversation ? "New conversation in the \(flavor.displayName) app · " + folder : "Open the installed \(flavor.displayName) app") {
                if app.canCreateConversation { self.newAppConversation(app, prompt: seed) }
                else { self.workspace.openApplication(app) }
            }
        }
        // A command is offered when its name is typed, or, with nothing typed, when it has something to do.
        let tab: String? = switch workspace.filter {
        case .all: workspace.query.isEmpty ? nil : "view"
        case .group(let id): groups.list.first { $0.id == id }?.name
        }
        let commands = BoardCommand.allCases.compactMap { command -> PaletteItem? in
            let count = workspace.targets(of: command).count
            guard q.isEmpty ? count > 0 : matches(command.title) else { return nil }
            let scope = command.everyTab ? nil : tab.map { "in \($0)" }
            return PaletteItem(id: command.id, symbol: command.symbol, color: Style.dim, title: command.title,
                               subtitle: [count == 0 ? "Nothing to do" : count == 1 ? "1 tile" : "\(count) tiles", scope]
                                   .compactMap { $0 }.joined(separator: " ")) {
                self.run(command)
            }
        }
        // ⇧⌘J's overlay, findable here too.
        let triage = workspace.state.queue.isEmpty || !matches("Triage Needs You") ? []
            : [PaletteItem(id: "triage", symbol: "rectangle.stack", color: Style.dim, title: "Triage Needs You",
                           subtitle: "\(workspace.state.queue.count) waiting · ⇧⌘J") { self.openTriage() }]

        // Hidden conversations are found as tiles, above.
        let reopen = workspace.recentlyClosed.tiles.filter { $0.kind != .agentSession && (matches("Reopen " + $0.title) || matches($0.subtitle)) }.map { closed in
            PaletteItem(id: "reopen-\(closed.id)", symbol: "arrow.uturn.backward", color: Style.dim,
                        title: "Reopen \(closed.title)", subtitle: "Closed · " + closed.subtitle) {
                self.reopen([closed.id], open: true)
            }
        }

        // The overseer: its chat, or what was typed put to it.
        let ask = PaletteItem(id: "overseer", symbol: "sparkles", color: Style.accent(.agentDesk),
                              title: q.isEmpty ? "Ask Tessera" : "Ask Tessera: “\(q.preview(50))”",
                              subtitle: "The overseer sees every tile and directs agents through Accord · ⌘O") {
            self.openOverseer(asking: q.isEmpty ? nil : q)
        }
        let urlMode = PaletteItem(id: "url-mode", symbol: "globe", color: Style.dim, title: "Open Web Tile…", subtitle: "⌘L") {
            DispatchQueue.main.async {
                self.paletteMode = .url
                self.showPalette = true
            }
        }
        let looksLikeURL = WebAddress.looksLikeAddress(q)
        let run = PaletteItem(id: "run", symbol: "play.fill", color: Style.dim, title: "Run \(q)", subtitle: "New terminal tile in " + folder) {
            self.create { $0.launch(command: q, cwd: cwd) }
        }
        // ⌘N: only what starts something, so a few letters and ⏎ always start it.
        if paletteMode == .new {
            if q.isEmpty { return presets + apps + [urlMode] + folders }
            return typedFolders.isEmpty ? presets + apps + folders + (looksLikeURL ? [openURL] : []) + [run] : folders
        }
        if q.isEmpty { return apps + presets + [urlMode, ask] + tiles + triage + commands + reopen }
        let search = PaletteItem(id: "search", symbol: "magnifyingglass", color: Style.dim, title: "Search the web for “\(q)”", subtitle: "New web tile") {
            self.create { $0.openBrowser(q) }
        }
        // Keep each append explicit: Xcode 26.0 cannot type-check the chained overloads in
        // reasonable time on the release CI runner.
        // A path is a folder to start in before it is anything else; a question is the overseer's.
        var results = typedFolders.isEmpty ? [] : folders
        let question = q.hasSuffix("?") || q.split(separator: " ").count >= 4
        if question { results.append(ask) }
        results.append(contentsOf: tiles)
        if typedFolders.isEmpty { results.append(contentsOf: folders) }
        if workspace.accord.searchQuery == q {
            let visible = Set(found.map { $0.tile.id })
            for session in workspace.accord.searchResults where !visible.contains(session.id) {
                results.append(PaletteItem(id:"shared-"+session.id,symbol:"network",color:Style.dim,title:session.title,subtitle:"Accord history · " + (session.summary ?? session.cwd)) {
                    self.workspace.openSharedSession(session)
                })
            }
        }
        if looksLikeURL { results.append(openURL) }
        results.append(contentsOf: presets)
        results.append(contentsOf: triage)
        results.append(contentsOf: commands)
        results.append(contentsOf: reopen)
        if !question { results.append(ask) }
        results.append(run)
        results.append(contentsOf: apps)
        if !looksLikeURL { results.append(search) }
        return results
    }
}
