import SwiftUI
import TesseraHost
import TesseraKit
import UniformTypeIdentifiers

/// The grid. Tiles are laid out by `GridLayout` so dozens fit a large display; opening one zooms a
/// full-size panel out of the tile's own position.
struct BoardView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        let workspace = model.workspace
        GeometryReader { geo in
            let ids = workspace.visibleIds
            // The grid keeps the chrome's inset from every edge of its area (a selected tile's ring
            // needs the room), and when it scrolls the inset scrolls with it.
            let inset = Style.Space.l
            let area = geo.frame(in: .named("window"))
            // (`insetBy` would answer an area smaller than the inset with a rectangle at infinity.)
            let board = CGRect(x: area.minX + inset, y: area.minY + inset,
                               width: max(area.width - 2 * inset, 0), height: max(area.height - 2 * inset, 0))
            let layout = Self.grid(count: ids.count, in: board.size)
            ZStack(alignment: .topLeading) {
                if ids.isEmpty {
                    EmptyBoard(filter: workspace.filter, query: workspace.query).frame(width: area.width, height: area.height)
                }
                ScrollViewReader { proxy in
                    ScrollView(layout.scrolls ? .vertical : [], showsIndicators: layout.scrolls) {
                        ZStack(alignment: .topLeading) {
                            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                                let origin = layout.origin(of: index, in: board.size)
                                BoardTile(id: id, size: layout.tileSize)
                                    .frame(width: layout.tileSize.width, height: layout.tileSize.height)
                                    .offset(x: origin.x, y: origin.y)
                                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                            }
                        }
                        .frame(width: board.width, height: max(board.height, layout.contentHeight), alignment: .topLeading)
                        .padding(inset)
                        .environment(\.tesseraHighlight, workspace.query.text)
                        .id(Self.gridId)
                        .onGeometryChange(for: CGFloat.self) { -$0.frame(in: .scrollView).minY } action: { model.boardScroll = $0 }
                        .animation(Style.Motion.standard, value: ids)
                        .animation(Style.Motion.standard, value: layout)
                    }
                    .scrollDisabled(!layout.scrolls)
                    // A scrolling board follows the selection, moving only as far as it takes to show it.
                    .onChange(of: workspace.selectedId) { _, selected in
                        guard layout.scrolls, let index = selected.flatMap(ids.firstIndex(of:)) else { return }
                        let offset = layout.scrollOffset(showing: index, height: board.height, current: model.boardScroll)
                        let range = layout.contentHeight - board.height
                        guard offset != model.boardScroll, range > 0 else { return }
                        // Aligning the same fraction of the grid and of the view puts it at exactly `offset`.
                        withAnimation(Style.Motion.standard) { proxy.scrollTo(Self.gridId, anchor: UnitPoint(x: 0, y: offset / range)) }
                    }
                }

                if let id = workspace.expandedId, workspace.exists(id) {
                    Style.scrim
                        .contentShape(Rectangle())
                        .onTapGesture { model.collapse() }
                        .transition(.opacity)
                        .zIndex(10)
                    // A panel per tile: going from one open tile to the next, each zooms to its own.
                    PanelContent(id: id)
                        .transition(ExpandedPanel.zoom(from: model.tileFrame(id), board: board, in: area))
                        .id(id)
                        .zIndex(11)
                    DoubleClickShield().zIndex(12)
                }
            }
            .onChange(of: board, initial: true) { _, frame in model.boardFrame = frame }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        // An open tile owns the keyboard: its terminal or page becomes first responder, which takes
        // focus from the board, and the board takes it back on close (see `AppModel.restoreFocus`).
        .onChange(of: model.workspace.expandedId) { _, open in if open == nil { focused = true } }
        .onChange(of: model.boardFocus) { focused = true }
        .onKeyPress(.leftArrow) { move(.left) }
        .onKeyPress(.rightArrow) { move(.right) }
        .onKeyPress(.upArrow) { move(.up) }
        .onKeyPress(.downArrow) { move(.down) }
        .onKeyPress(.return) {
            guard model.workspace.expandedId == nil, let id = model.workspace.selectedId else { return .ignored }
            model.open(id)
            return .handled
        }
        .onKeyPress(.escape) {
            guard model.workspace.expandedId == nil, !model.workspace.query.isEmpty else { return .ignored }
            model.clearFilter()
            return .handled
        }
        // Anything else typed on the board filters it: the typing goes on in the top bar's field.
        .onKeyPress(phases: .down) { press in
            let query = model.workspace.query
            guard model.workspace.expandedId == nil, press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
            if press.key == .delete, query.hasText {
                model.beginFilter(text: String(query.text.dropLast()))
            } else if Self.isText(press.characters), query.hasText || press.characters != " " {
                model.beginFilter(text: query.text + press.characters)
            } else {
                return .ignored
            }
            return .handled
        }
    }

    /// Whether a key types something (the arrows and function keys arrive as private-use characters).
    private static func isText(_ characters: String) -> Bool {
        !characters.isEmpty && characters.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }
    }

    /// Arrow keys move the selection only while the board itself is showing.
    private func move(_ step: GridMove) -> KeyPress.Result {
        guard model.workspace.expandedId == nil else { return .ignored }
        model.move(step)
        return .handled
    }

    private static let gridId = "grid"

    /// The board's one layout: what is drawn, where a tile opens from, and what the arrow keys walk.
    static func grid(count: Int, in size: CGSize) -> TesseraKit.GridLayout {
        GridLayout.fit(count: count, in: size, spacing: Style.Space.gutter, aspect: 16.0 / 10.5, minTileWidth: 230)
    }
}

struct EmptyBoard: View {
    @Environment(AppModel.self) private var model
    let filter: Workspace.Filter
    /// What narrows the board: with a filter on, a tab may have tiles and show none.
    let query: BoardQuery

    private var narrowed: Bool { !query.isEmpty }

    private var title: String {
        if query == BoardQuery(chips: [.needsYou]) { return "Nothing needs you." }
        if narrowed { return "Nothing matches." }
        return filter == .all ? "An empty board." : "An empty tab."
    }

    var body: some View {
        VStack(spacing: Style.Space.xl) {
            TesseraGlyph().frame(width: 44, height: 44)
            Text(title).font(Style.display).foregroundStyle(Style.ink)
            if narrowed {
                Text("Esc shows every tile again.").font(Style.body).foregroundStyle(Style.dim)
            } else if case .group = filter {
                Text("Drag tiles onto this tab, or start one here with ⌘K.").font(Style.body).foregroundStyle(Style.dim)
            }
            if filter == .all, !narrowed {
                HStack(spacing: Style.Space.gutter) {
                    ForEach(model.workspace.installedApps, id: \.self) { app in
                        start(app.name, app.flavor) { model.newAppConversation(app) }
                    }
                    ForEach(model.workspace.presets.prefix(4)) { preset in
                        start(preset.name, preset.flavor) {
                            model.create { $0.launch(command: preset.command, cwd: model.contextDirectory) }
                        }
                    }
                }
                Text("⌘K for everything · ⌘T shell · ⌘L web tile").font(Style.caption).foregroundStyle(Style.muted)
            }
        }
    }

    private func start(_ name: String, _ flavor: AgentFlavor, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(name) } icon: { Image(systemName: flavor.symbol).foregroundStyle(Style.accent(flavor)) }
        }
        .buttonStyle(.capsule)
    }
}

// MARK: - Tile

/// Reads only its own tile, so one tile's change re-renders just that tile.
struct BoardTile: View {
    @Environment(AppModel.self) private var model
    let id: String
    let size: CGSize

    var body: some View {
        if let info = model.workspace.info(id) { TileView(info: info, size: size) }
    }
}

struct TileView: View {
    @Environment(AppModel.self) private var model
    let info: TileInfo
    let size: CGSize
    @State private var hovering = false
    @State private var renaming = false
    /// Scrolled out of view, a tile's continuous effects stop.
    @State private var onScreen = true

    var body: some View {
        let workspace = model.workspace
        let compact = size.width < 280
        TileCard(info: info, isSelected: workspace.selectedId == info.id, isHovered: hovering, compact: compact) {
            content
        }
        .environment(\.tesseraMotion, onScreen)
        .onGeometryChange(for: Bool.self) { g in
            g.bounds(of: .scrollView).map { CGRect(origin: .zero, size: g.size).intersects($0) } ?? true
        } action: { onScreen = $0 }
        .overlay(alignment: .topTrailing) {
            if hovering {
                TileHoverControls(info: info)
                    .padding(.trailing, Style.Space.xs)
                    .padding(.top, TileCard<EmptyView>.headerHeight(compact: compact) + Style.Space.xs)
                    .transition(.opacity)
            }
        }
        .animation(Style.Motion.quick, value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture(count: 1) { model.open(info.id) }
        .onDrag {
            NSItemProvider(object: info.id as NSString)
        }
        .onDrop(of: [.text], delegate: TileDropDelegate(target: info.id, workspace: workspace))
        .contextMenu { TileMenu(info: info) { renaming = true } }
        .modifier(RenamePopover(info: info, isPresented: $renaming))
    }

    @ViewBuilder
    private var content: some View {
        let workspace = model.workspace
        switch info.kind {
        case .terminal:
            if let session = workspace.terminals[info.id] {
                TerminalTileContent(session: session)
                    .terminalTileInset()
                    .overlay { EndedOverlay(info: info) }
            }
        case .browser:
            if let browser = workspace.browsers[info.id] {
                BrowserTileContent(browser: browser, isExpanded: workspace.expandedId == info.id)
            }
        case .agentSession:
            ConversationThumbnail(snapshot: workspace.agents.session(info.id)?.snapshot, flavor: info.flavor,
                                  maxItems: size.height > 300 ? 20 : 12,
                                  fontScale: ConversationThumbnail.terminalMatchedScale)
        }
    }
}

/// The buttons a hovered tile shows: a terminal's Shut Down, Resume or Restart, and, set apart from
/// it because it ends the tile, Close (for an app conversation, Hide).
struct TileHoverControls: View {
    @Environment(AppModel.self) private var model
    let info: TileInfo

    var body: some View {
        HStack(spacing: Style.Space.gutter) {
            if info.kind == .terminal, let action = model.actions(for: info).first { button(action) }
            button(model.closeAction(for: info))
        }
    }

    private func button(_ action: TileAction) -> some View {
        Button(action: action.run) {
            Image(systemName: action.symbol)
                .font(Style.ui(.caption, .bold))
                .frame(width: 20, height: 20)
                .background(Style.scrim, in: Circle())
                .foregroundStyle(Style.ink)
        }
        .buttonStyle(.plain)
        .help(action.title)
    }
}

struct TileDropDelegate: DropDelegate {
    let target: String
    let workspace: Workspace

    func performDrop(info: DropInfo) -> Bool {
        info.itemProviders(for: [.text]).loadTileId { id in
            withAnimation(Style.Motion.standard) { workspace.move(id, before: target) }
        }
    }
}

extension [NSItemProvider] {
    /// The id a dragged tile carries, handed to `drop` on the main actor. False when nothing was dropped.
    func loadTileId(_ drop: @escaping @MainActor (String) -> Void) -> Bool {
        guard let provider = first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? String else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { drop(id) } }
        }
        return true
    }
}

/// Reads `revision` so only this tile redraws when its screen changes.
struct TerminalTileContent: View {
    let session: TerminalSession
    @Environment(\.tesseraPrivacy) private var privacy

    var body: some View {
        TerminalThumbnail(terminal: session.terminal, revision: session.revision, obscured: privacy)
            .equatable()
    }
}

struct BrowserTileContent: View {
    let browser: BrowserSession
    let isExpanded: Bool
    @Environment(\.tesseraPrivacy) private var privacy
    @Environment(\.tesseraMotion) private var onScreen

    var body: some View {
        if isExpanded {
            PageStill(browser: browser)
                .overlay { if privacy { PrivateWebCover(browser: browser) } else { Style.pageDim } }
        } else if onScreen {
            ScaledWebHost(webView: browser.webView)
                .overlay { if privacy { PrivateWebCover(browser: browser) } else { Style.pageDim.allowsHitTesting(false) } }
        } else {
            // Scrolled out of view, the page leaves the window too, so WebKit throttles it.
            Style.terminalBackground
        }
    }
}

/// The page as last captured, standing in where the live view isn't.
struct PageStill: View {
    let browser: BrowserSession

    var body: some View {
        if let image = browser.snapshot {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).clipped()
        } else {
            Color.black
        }
    }
}

/// Web pages render out of process and their text can't be re-drawn, so in privacy mode the live
/// page is covered by a coarse mosaic of itself — colorful and current, but unreadable.
struct PrivateWebCover: View {
    let browser: BrowserSession

    var body: some View {
        ZStack {
            Style.deck
            if let image = browser.mosaic {
                Image(nsImage: image).interpolation(.none).resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipped()
            }
        }
        .allowsHitTesting(false)
        .task {
            while !Task.isCancelled {
                browser.refreshSnapshot(force: true)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

/// Over a terminal that isn't running, on its tile and in its open panel alike: the way back
/// (Resume after a shut-down, Restart after an exit). On the tile that is all, its pill and footer
/// saying how it ended; the panel has room for the whole story. There ⏎ presses the button and Esc
/// goes back to the board; typing has nowhere to go.
struct EndedOverlay: View {
    @Environment(AppModel.self) private var model
    let info: TileInfo
    var inPanel = false

    var body: some View {
        if info.activity.hasEnded, let action = model.actions(for: info).first {
            let suspended = model.workspace.isSuspended(info.id)
            ZStack {
                Style.scrim
                VStack(spacing: Style.Space.m) {
                    if inPanel {
                        if suspended {
                            Label("Shut down", systemImage: "power").font(Style.label).foregroundStyle(Style.ink)
                        }
                        Text(info.detail ?? "Exited")
                            .font(Style.caption)
                            .foregroundStyle(suspended ? Style.dim : Style.state(info.activity))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, Style.Space.gutter)
                    }
                    Button(action.title, action: action.run)
                        .buttonStyle(inPanel ? .capsulePrimary : .capsule)
                        .keyboardShortcut(inPanel ? .defaultAction : nil)
                }
                if inPanel { EscToBoard() }
            }
        }
    }
}

/// Esc goes back to the board wherever the content has no use for it: a transcript, a terminal
/// that has ended. (A live terminal or page gets the key itself.)
struct EscToBoard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("") { model.collapse() }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}
