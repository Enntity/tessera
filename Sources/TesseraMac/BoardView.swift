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
            let tiles = workspace.visibleTiles
            let layout = GridLayout.fit(count: tiles.count, in: geo.size, spacing: 10, aspect: 16.0 / 10.5, minTileWidth: 230)
            let board = geo.frame(in: .named("window"))
            ZStack(alignment: .topLeading) {
                if tiles.isEmpty {
                    EmptyBoard(filter: workspace.filter).frame(width: geo.size.width, height: geo.size.height)
                }
                ScrollView(layout.scrolls ? .vertical : [], showsIndicators: layout.scrolls) {
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                            let origin = layout.origin(of: index, in: geo.size)
                            TileView(info: tile, size: layout.tileSize)
                                .frame(width: layout.tileSize.width, height: layout.tileSize.height)
                                .offset(x: origin.x, y: origin.y)
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                    }
                    .frame(width: geo.size.width, height: max(geo.size.height, layout.contentHeight), alignment: .topLeading)
                    .animation(.spring(duration: 0.45, bounce: 0.15), value: tiles.map(\.id))
                    .animation(.spring(duration: 0.45, bounce: 0.15), value: layout)
                }
                .scrollDisabled(!layout.scrolls)

                if let id = workspace.expandedId, workspace.info(id) != nil {
                    ExpandedPanel(id: id, board: board, source: model.tileFrames[id])
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
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
        let cols = GridLayout.fit(count: model.workspace.visibleTiles.count, in: size, spacing: 10, aspect: 16.0 / 10.5, minTileWidth: 230).columns
        model.cycle(delta * max(cols, 1))
        return .handled
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

struct TileView: View {
    @Environment(AppModel.self) private var model
    let info: TileInfo
    let size: CGSize
    @State private var hovering = false
    @State private var renaming = false
    @State private var draftTitle = ""

    var body: some View {
        let workspace = model.workspace
        let compact = size.width < 280
        TileCard(info: info, isSelected: workspace.selectedId == info.id, compact: compact) {
            content(compact: compact)
        }
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
        .background(GeometryReader { g in
            Color.clear
                .onAppear { model.tileFrames[info.id] = g.frame(in: .named("window")) }
                .onChange(of: g.frame(in: .named("window"))) { _, f in model.tileFrames[info.id] = f }
        })
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
            ConversationThumbnail(snapshot: workspace.agents.sessions[info.id]?.snapshot, flavor: info.flavor,
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
        Button("Open") { model.open(info.id) }
        if info.kind == .agentSession {
            Button("Open in \(info.flavor.displayName)") {
                workspace.openNative(info.id, at: model.tileFrames[info.id].flatMap(model.screenRect(fromWindow:)))
            }
            if let resume = workspace.agents.sessions[info.id]?.resumeCommand {
                Button("Continue in Terminal") {
                    workspace.launch(command: resume, cwd: workspace.agents.sessions[info.id]?.cwd)
                }
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

    var body: some View {
        if isExpanded {
            if let image = browser.snapshot {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).clipped()
                    .overlay { if privacy { PrivateWebCover(browser: browser) } }
            } else {
                Color.black
            }
        } else {
            ScaledWebHost(webView: browser.webView)
                .overlay { if privacy { PrivateWebCover(browser: browser) } }
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
            if let image = browser.snapshot.flatMap(Self.mosaic) {
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

    /// Downsample to wide, short cells; drawn without interpolation, lines of text become bars —
    /// the same look as a terminal minimap.
    static func mosaic(_ image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = max(1, cg.width / 16), h = max(1, cg.height / 5)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Keep the page's shape: stretched back to it, the pixels become the wide, short cells.
        return ctx.makeImage().map { NSImage(cgImage: $0, size: image.size) }
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
