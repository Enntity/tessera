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
            let layout = Self.grid(count: ids.count, in: geo.size)
            let board = geo.frame(in: .named("window"))
            ZStack(alignment: .topLeading) {
                if ids.isEmpty {
                    EmptyBoard(filter: workspace.filter).frame(width: geo.size.width, height: geo.size.height)
                }
                ScrollViewReader { proxy in
                    ScrollView(layout.scrolls ? .vertical : [], showsIndicators: layout.scrolls) {
                        ZStack(alignment: .topLeading) {
                            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                                let origin = layout.origin(of: index, in: geo.size)
                                BoardTile(id: id, size: layout.tileSize)
                                    .frame(width: layout.tileSize.width, height: layout.tileSize.height)
                                    .offset(x: origin.x, y: origin.y)
                                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                            }
                        }
                        .frame(width: geo.size.width, height: max(geo.size.height, layout.contentHeight), alignment: .topLeading)
                        .id(Self.gridId)
                        .onGeometryChange(for: CGFloat.self) { -$0.frame(in: .scrollView).minY } action: { model.boardScroll = $0 }
                        .animation(.spring(duration: 0.45, bounce: 0.15), value: ids)
                        .animation(.spring(duration: 0.45, bounce: 0.15), value: layout)
                    }
                    .scrollDisabled(!layout.scrolls)
                    // A scrolling board follows the selection, moving only as far as it takes to show it.
                    .onChange(of: workspace.selectedId) { _, selected in
                        guard layout.scrolls, let index = selected.flatMap(ids.firstIndex(of:)) else { return }
                        let offset = layout.scrollOffset(showing: index, height: geo.size.height, current: model.boardScroll)
                        let range = layout.contentHeight - geo.size.height
                        guard offset != model.boardScroll, range > 0 else { return }
                        // Aligning the same fraction of the grid and of the view puts it at exactly `offset`.
                        withAnimation(.spring(duration: 0.3)) { proxy.scrollTo(Self.gridId, anchor: UnitPoint(x: 0, y: offset / range)) }
                    }
                }

                if let id = workspace.expandedId, workspace.exists(id) {
                    ExpandedPanel(id: id, board: board, source: model.tileFrame(id))
                        .transition(.opacity)
                        .zIndex(10)
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
        GridLayout.fit(count: count, in: size, spacing: 10, aspect: 16.0 / 10.5, minTileWidth: 230)
    }
}

struct EmptyBoard: View {
    @Environment(AppModel.self) private var model
    let filter: Workspace.Filter

    private var title: String {
        switch filter {
        case .all: "An empty board."
        case .attention: "Nothing needs you."
        case .group: "An empty tab."
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            TesseraGlyph().frame(width: 44, height: 44).opacity(0.8)
            Text(title).font(Style.ui(20, .semibold)).foregroundStyle(Style.ink)
            if case .group = filter {
                Text("Drag tiles onto this tab, or start one here with ⌘K.").font(Style.ui(13)).foregroundStyle(Style.dim)
            }
            if filter == .all {
                HStack(spacing: 10) {
                    ForEach(model.workspace.installedApps, id: \.self) { app in
                        Button { model.newAppConversation(app) } label: {
                            Label(app.name, systemImage: app.flavor.symbol)
                                .font(Style.ui(12, .semibold))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Style.accent(app.flavor).opacity(0.14), in: Capsule())
                                .foregroundStyle(Style.accent(app.flavor))
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(model.workspace.presets.prefix(4)) { preset in
                        Button {
                            model.create { $0.launch(command: preset.command, cwd: model.contextDirectory) }
                        } label: {
                            Label(preset.name, systemImage: preset.flavor.symbol)
                                .font(Style.ui(12, .semibold))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Style.accent(preset.flavor).opacity(0.14), in: Capsule())
                                .foregroundStyle(Style.accent(preset.flavor))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("⌘K for everything · ⌘T shell · ⌘L web tile").font(Style.mono(11)).foregroundStyle(Style.faint)
            }
        }
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
        TileCard(info: info, isSelected: workspace.selectedId == info.id, compact: compact) {
            content
        }
        .environment(\.tesseraMotion, onScreen)
        .onGeometryChange(for: Bool.self) { g in
            g.bounds(of: .scrollView).map { CGRect(origin: .zero, size: g.size).intersects($0) } ?? true
        } action: { onScreen = $0 }
        .overlay(alignment: .topTrailing) {
            if hovering {
                TileHoverControls(info: info)
                    .padding(.trailing, 4)
                    .padding(.top, compact ? 24 : 28)
                    .transition(.opacity)
            }
        }
        .scaleEffect(hovering ? 1.012 : 1)
        .animation(.spring(duration: 0.25), value: hovering)
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
        HStack(spacing: 10) {
            if info.kind == .terminal, let action = model.actions(for: info).first { button(action) }
            button(model.closeAction(for: info))
        }
    }

    private func button(_ action: TileAction) -> some View {
        Button(action: action.run) {
            Image(systemName: action.symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(.black.opacity(0.55), in: Circle())
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
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let id = obj as? String else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    withAnimation(.spring(duration: 0.4)) { workspace.move(id, before: target) }
                }
            }
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
            if let image = browser.snapshot {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).clipped()
                    .overlay { if privacy { PrivateWebCover(browser: browser) } }
            } else {
                Color.black
            }
        } else if onScreen {
            ScaledWebHost(webView: browser.webView)
                .overlay { if privacy { PrivateWebCover(browser: browser) } }
        } else {
            // Scrolled out of view, the page leaves the window too, so WebKit throttles it.
            Style.terminalBackground
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

/// Over a terminal that isn't running, on its tile and in its open panel alike: what happened, and
/// the way back (Resume after a shut-down, Restart after an exit). In the panel ⏎ presses it and
/// Esc goes back to the board; typing has nowhere to go.
struct EndedOverlay: View {
    @Environment(AppModel.self) private var model
    let info: TileInfo
    var inPanel = false

    var body: some View {
        if info.activity.hasEnded, let action = model.actions(for: info).first {
            let suspended = model.workspace.isSuspended(info.id)
            ZStack {
                Color.black.opacity(0.6)
                VStack(spacing: 6) {
                    if suspended {
                        Label("Shut down", systemImage: "power").font(Style.ui(12, .semibold)).foregroundStyle(Style.ink)
                    }
                    Text(info.detail ?? "Exited")
                        .font(Style.mono(9.5))
                        .foregroundStyle(suspended ? Style.dim : Style.state(info.activity))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 10)
                    Button(action.title, action: action.run)
                        .buttonStyle(.borderedProminent)
                        .tint(Style.cyan.opacity(0.6))
                        .controlSize(.small)
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
