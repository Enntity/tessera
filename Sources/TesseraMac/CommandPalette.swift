import SwiftUI
import TesseraHost
import TesseraKit

/// ⌘K: find any tile, launch any agent, run any command, open any URL, or act on the whole
/// board — one field.
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
                    Image(systemName: model.paletteMode == .url ? "globe" : "command").foregroundStyle(Style.dim)
                    TextField(model.paletteMode == .url ? "URL or search" : "Find a tile, launch, run, or open a URL…", text: $query)
                        .textFieldStyle(.plain)
                        .font(Style.title)
                        .focused($focused)
                        .onSubmit { run(items) }
                    Text(model.contextDirectory.abbreviatingHome)
                        .font(Style.caption).foregroundStyle(Style.muted).lineLimit(1)
                }
                .padding(Style.Space.xl)
                Hairline()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: Style.Space.xxs) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                row(item, selected: i == selection)
                                    .id(i)
                                    .onTapGesture {
                                        item.run()
                                        dismiss()
                                    }
                            }
                        }
                        .padding(Style.Space.s)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: selection) { _, s in proxy.scrollTo(s) }
                }
            }
            .frame(width: 640)
            .overlaySurface()
            .padding(.top, 120)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selection = 0 }
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

    private func run(_ items: [PaletteItem]) {
        guard items.indices.contains(selection) else { return }
        items[selection].run()
        dismiss()
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
    let run: () -> Void
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
                               title: seed.map { "Ask \(flavor.displayName) app: “\($0.preview(50))”" } ?? app.newLabel,
                               subtitle: "New conversation in the \(flavor.displayName) app · " + folder) {
                self.newAppConversation(app, prompt: seed)
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
        // Hidden conversations are found as tiles, above.
        let reopen = workspace.recentlyClosed.tiles.filter { $0.kind != .agentSession && (matches("Reopen " + $0.title) || matches($0.subtitle)) }.map { closed in
            PaletteItem(id: "reopen-\(closed.id)", symbol: "arrow.uturn.backward", color: Style.dim,
                        title: "Reopen \(closed.title)", subtitle: "Closed · " + closed.subtitle) {
                self.reopen([closed.id], open: true)
            }
        }

        if q.isEmpty {
            let urlMode = PaletteItem(id: "url-mode", symbol: "globe", color: Style.dim, title: "Open Web Tile…", subtitle: "⌘L") {
                DispatchQueue.main.async {
                    self.paletteMode = .url
                    self.showPalette = true
                }
            }
            return apps + presets + [urlMode] + tiles + commands + reopen
        }
        let looksLikeURL = WebAddress.looksLikeAddress(q)
        let run = PaletteItem(id: "run", symbol: "play.fill", color: Style.dim, title: "Run \(q)", subtitle: "New terminal tile in " + folder) {
            self.create { $0.launch(command: q, cwd: cwd) }
        }
        let search = PaletteItem(id: "search", symbol: "magnifyingglass", color: Style.dim, title: "Search the web for “\(q)”", subtitle: "New web tile") {
            self.create { $0.openBrowser(q) }
        }
        return tiles + (looksLikeURL ? [openURL] : []) + presets + commands + reopen + [run] + apps + (looksLikeURL ? [] : [search])
    }
}
