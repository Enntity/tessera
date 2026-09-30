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
                    .onGeometryChange(for: CGFloat.self) { -$0.frame(in: .scrollView).minY } action: { model.boardScroll = $0 }
                    .animation(.spring(duration: 0.45, bounce: 0.15), value: ids)
                    .animation(.spring(duration: 0.45, bounce: 0.15), value: layout)
                }
                .scrollDisabled(!layout.scrolls)

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
        // An open tile owns the keyboard: the board lets go of focus so its shortcuts can't
        // intercept keys meant for a terminal or page, and takes it back on close.
        .onChange(of: model.workspace.expandedId) { _, open in focused = open == nil }
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
        .onKeyPress(.upArrow) { moveRow(-1) }
        .onKeyPress(.downArrow) { moveRow(1) }
        .onKeyPress(.return) {
            guard model.workspace.expandedId == nil, let id = model.workspace.selectedId else { return .ignored }
            model.open(id)
            return .handled
        }
        .onKeyPress(.escape) {
            // Terminals and pages use Esc themselves (agents: interrupt), so it only closes a
            // conversation transcript; ⌘⏎ closes anything.
            guard let open = model.workspace.expandedId, model.workspace.info(open)?.kind == .agentSession else { return .ignored }
            model.collapse()
            return .handled
        }
    }

    /// Arrow keys move the selection only while the board itself is showing.
    private func move(_ delta: Int) -> KeyPress.Result {
        guard model.workspace.expandedId == nil else { return .ignored }
        model.cycle(delta)
        return .handled
    }

    private func moveRow(_ delta: Int) -> KeyPress.Result {
        guard model.workspace.expandedId == nil, let window = model.window else { return .ignored }
        let size = window.contentView?.bounds.size ?? .zero
        let cols = Self.grid(count: model.workspace.visibleIds.count, in: size).columns
        model.cycle(delta * max(cols, 1))
        return .handled
    }

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
                            Label(app.flavor.displayName + " app", systemImage: app.flavor.symbol)
                                .font(Style.ui(12, .semibold))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Style.accent(app.flavor).opacity(0.14), in: Capsule())
                                .foregroundStyle(Style.accent(app.flavor))
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(model.workspace.presets.prefix(4)) { preset in
                        Button {
                            model.workspace.launch(command: preset.command, cwd: model.contextDirectory)
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
    @State private var draftTitle = ""
    /// Scrolled out of view, a tile's continuous effects stop.
    @State private var onScreen = true

    var body: some View {
        let workspace = model.workspace
        let compact = size.width < 280
        TileCard(info: info, isSelected: workspace.selectedId == info.id, compact: compact) {
            content(compact: compact)
        }
        .environment(\.tesseraMotion, onScreen)
        .onGeometryChange(for: Bool.self) { g in
            g.bounds(of: .scrollView).map { CGRect(origin: .zero, size: g.size).intersects($0) } ?? true
        } action: { onScreen = $0 }
        .overlay(alignment: .topTrailing) {
            if hovering {
                HStack(spacing: 2) {
                    if info.kind == .terminal {
                        if workspace.terminals[info.id]?.isSuspended == true {
                            tileButton("play.fill") { workspace.resume(info.id) }
                        } else {
                            tileButton("power") { workspace.shutDown(info.id) }
                        }
                    }
                    tileButton("xmark") { withAnimation(.spring(duration: 0.3)) { workspace.close(info.id) } }
                }
                .padding(.trailing, 4)
                .padding(.top, compact ? 24 : 28)
                .transition(.opacity)
            }
        }
        .scaleEffect(hovering ? 1.012 : 1)
        .animation(.spring(duration: 0.25), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture(count: 1) {
            workspace.selectedId = info.id
            model.open(info.id)
        }
        .onDrag {
            NSItemProvider(object: info.id as NSString)
        }
        .onDrop(of: [.text], delegate: TileDropDelegate(target: info.id, workspace: workspace))
        .contextMenu { menu }
        .popover(isPresented: $renaming) {
            TextField("Title", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .padding()
                .onSubmit {
                    workspace.rename(info.id, to: draftTitle)
                    renaming = false
                }
        }
    }

    @ViewBuilder
    private func content(compact: Bool) -> some View {
        let workspace = model.workspace
        switch info.kind {
        case .terminal:
            if let session = workspace.terminals[info.id] {
                TerminalTileContent(session: session)
                    .overlay {
                        if session.isSuspended {
                            ExitedOverlay(info: info, title: "Shut down", action: "Resume") { workspace.resume(info.id) }
                        } else if info.activity == .exited || info.activity == .failed {
                            ExitedOverlay(info: info, title: nil, action: "Restart") { workspace.restart(info.id) }
                        }
                    }
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

    private func tileButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(.black.opacity(0.55), in: Circle())
                .foregroundStyle(Style.ink)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var menu: some View {
        let workspace = model.workspace
        if workspace.opensInApp(info.id) {
            Button("Open in \(info.flavor.displayName)") { model.open(info.id) }
            Button("Show Transcript") { model.showTranscript(info.id) }
        } else {
            Button("Open") { model.open(info.id) }
        }
        if info.kind == .agentSession {
            if let session = workspace.agents.session(info.id), let resume = session.resumeCommand {
                Button("Continue in Terminal") { workspace.launch(command: resume, cwd: session.cwd) }
            }
        }
        if info.kind == .terminal {
            Button("Rename…") {
                draftTitle = info.title
                renaming = true
            }
            if workspace.terminals[info.id]?.isSuspended == true {
                Button("Resume") { workspace.resume(info.id) }
            } else {
                Button("Shut Down") { workspace.shutDown(info.id) }
                Button("Restart") { workspace.restart(info.id) }
            }
        }
        if info.attention { Button("Mark as Seen") { workspace.acknowledge(info.id) } }
        Menu("Move to Tab") {
            let current = workspace.groups.group(of: info.id)?.id
            ForEach(workspace.groups.list) { group in
                Button(group.name) { withAnimation(.spring(duration: 0.4)) { workspace.move(tile: info.id, toGroup: group.id) } }
                    .disabled(group.id == current)
            }
            if !workspace.groups.list.isEmpty { Divider() }
            Button("New Tab with This Tile") {
                withAnimation(.spring(duration: 0.4)) {
                    _ = workspace.createGroup(named: Self.suggestedTabName(info), with: info.id)
                }
            }
            if current != nil {
                Button("Remove from Tab") { withAnimation(.spring(duration: 0.4)) { workspace.move(tile: info.id, toGroup: nil) } }
            }
        }
        Divider()
        Button(info.kind == .agentSession ? "Hide" : "Close", role: .destructive) { workspace.close(info.id) }
    }
}

extension TileView {
    /// A new tab is named after the tile's folder or site; rename it from the tab's menu.
    static func suggestedTabName(_ info: TileInfo) -> String {
        let last = (info.subtitle as NSString).lastPathComponent
        return last.isEmpty || last == "~" ? info.title : last
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

struct ExitedOverlay: View {
    let info: TileInfo
    /// Headline; nil shows the exit detail alone.
    let title: String?
    let action: String
    let perform: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(spacing: 6) {
                if let title {
                    Label(title, systemImage: "power").font(Style.ui(12, .semibold)).foregroundStyle(Style.ink)
                }
                Text(info.detail ?? "Exited")
                    .font(Style.mono(9.5))
                    .foregroundStyle(title == nil ? Style.state(info.activity) : Style.dim)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                Button(action, action: perform)
                    .buttonStyle(.borderedProminent)
                    .tint(Style.cyan.opacity(0.6))
                    .controlSize(.small)
            }
        }
    }
}
