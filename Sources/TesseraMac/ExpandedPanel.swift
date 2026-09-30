import AppKit
import SwiftUI
import TesseraHost
import TesseraKit
import WebKit

/// The opened tile. It grows out of the tile's own rectangle and settles centred on it, so the
/// user's eyes never have to travel, and goes back into it the same way.
enum ExpandedPanel {
    /// Where the panel grows from: the tile, or the board's centre.
    static func origin(from source: CGRect?, board: CGRect) -> CGRect {
        source ?? CGRect(x: board.midX - 150, y: board.midY - 100, width: 300, height: 200)
    }

    /// Where the panel settles for a tile at `source`: as tall as the grid, most of its width.
    static func target(from source: CGRect?, board: CGRect) -> CGRect {
        let preferred = CGSize(width: max(board.width * 0.8, min(board.width, 900)), height: board.height)
        return GridLayout.expandedFrame(from: origin(from: source, board: board), in: board, preferred: preferred)
    }

    /// Out of the tile at `source` and back into it. `board` is the grid's rectangle and `area` the
    /// rectangle the panel is laid out in (both in window coordinates).
    static func zoom(from source: CGRect?, board: CGRect, in area: CGRect) -> AnyTransition {
        let tile = origin(from: source, board: board).offsetBy(dx: -area.minX, dy: -area.minY)
        let open = target(from: source, board: board).offsetBy(dx: -area.minX, dy: -area.minY)
        return .modifier(active: PanelZoomEffect(progress: 0, tile: tile, open: open),
                         identity: PanelZoomEffect(progress: 1, tile: tile, open: open))
    }
}

/// The open panel at `progress` of the way from its tile (see `PanelZoom`). The content keeps its
/// open size throughout, so a terminal inside is never resized.
struct PanelZoomEffect: ViewModifier, Animatable {
    /// 0: on the tile. 1: open.
    var progress: CGFloat
    let tile: CGRect
    let open: CGRect

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let zoom = PanelZoom(from: tile, to: open, progress: progress)
        content
            .frame(width: open.width, height: open.height)
            .frame(width: zoom.shown.width, height: zoom.shown.height, alignment: .top)
            .overlaySurface()
            .scaleEffect(zoom.scale, anchor: .topLeading)
            .offset(x: zoom.origin.x, y: zoom.origin.y)
            // Faint on the tile, solid by the time it is open.
            .opacity(0.3 + 0.7 * min(progress, 1))
    }
}

/// Up while a panel has only just begun to open: a double-click's second click lands then, and must
/// reach neither the terminal or page inside nor the backdrop (which would close the panel).
struct DoubleClickShield: View {
    @State private var up = true

    var body: some View {
        ZStack {
            if up { Color.clear.contentShape(Rectangle()).onTapGesture {} }
        }
        .task {
            try? await Task.sleep(for: .seconds(min(NSEvent.doubleClickInterval, 0.5)))
            up = false
        }
    }
}

struct PanelContent: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        let workspace = model.workspace
        if let info = workspace.info(id) {
            VStack(spacing: 0) {
                PanelHeader(info: info)
                switch info.kind {
                case .terminal:
                    if let session = workspace.terminals[id] {
                        ReparentHost(view: session.view, focus: !info.activity.hasEnded)
                            .overlay {
                                // Same word blocks as the tiles; the live terminal underneath keeps the keyboard.
                                if model.privacyMode {
                                    TerminalTileContent(session: session).allowsHitTesting(false)
                                }
                            }
                            .overlay { EndedOverlay(info: info, inPanel: true) }
                            .padding(.horizontal, Style.Space.m)
                            .padding(.vertical, Style.Space.s)
                            .background(Style.terminalBackground)
                            // The keyboard leaves a terminal that ends while open, and returns once it runs again.
                            .onChange(of: info.activity.hasEnded) { model.restoreFocus() }
                    }
                case .browser:
                    if let browser = workspace.browsers[id] {
                        ReparentHost(view: browser.webView, focus: true)
                            // The page is back on its tile the moment the panel closes; its last
                            // still stands in here while the panel goes.
                            .background { PageStill(browser: browser) }
                            .overlay { if model.privacyMode { PrivateWebCover(browser: browser) } }
                    }
                case .agentSession:
                    AgentPanel(id: id)
                }
            }
        }
    }
}

struct PanelHeader: View {
    @Environment(AppModel.self) private var model
    let info: TileInfo
    @State private var urlText = ""
    @State private var renaming = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        let workspace = model.workspace
        HStack(spacing: Style.Space.gutter) {
            Image(systemName: info.flavor.symbol).foregroundStyle(Style.accent(info.flavor))
            if info.kind == .browser, let browser = workspace.browsers[info.id] {
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right") }
                TextField("URL", text: $urlText)
                    .textFieldStyle(.plain)
                    .font(Style.mono(.label))
                    .foregroundStyle(Style.ink)
                    .padding(.horizontal, Style.Space.m).padding(.vertical, Style.Space.xs)
                    .background(Style.Neutral.hover, in: Style.shape(Style.Radius.s))
                    .focused($addressFocused)
                    .onAppear { urlText = info.url ?? "" }
                    .onChange(of: info.url) { _, u in urlText = u ?? "" }
                    .onChange(of: model.addressFocus) { addressFocused = true }
                    .onSubmit {
                        if let url = WebAddress.normalize(urlText) { browser.load(url) }
                        model.restoreFocus()
                    }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(info.title).font(Style.ui(.body, .semibold)).foregroundStyle(Style.ink).lineLimit(1)
                    Text(info.subtitle).font(Style.caption).foregroundStyle(Style.muted).lineLimit(1)
                }
                Spacer()
            }
            StatePill(activity: info.activity)
            if let cols = info.cols, let rows = info.rows {
                Text("\(cols)×\(rows)").font(Style.caption).foregroundStyle(Style.muted)
            }
            ForEach(model.actions(for: info)) { headerButton($0) }
            Menu {
                TileMenu(info: info, inPanel: true) { renaming = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(Style.dim)
            .fixedSize()
            .help("More")
            .modifier(RenamePopover(info: info, isPresented: $renaming))
            headerButton(model.closeAction(for: info))
            // Closing ends the tile; going back doesn't. They sit apart.
            Hairline(.vertical).frame(height: Style.Space.xl)
            Button { model.collapse() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                .help("Back to board (⌘⏎)")
        }
        .buttonStyle(.plain)
        .font(Style.body)
        .foregroundStyle(Style.dim)
        .padding(.horizontal, Style.Space.l)
        .frame(height: Style.Metrics.panelHeader)
        .background(Style.glass)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func headerButton(_ action: TileAction) -> some View {
        Button(action: action.run) { Image(systemName: action.symbol) }
            .help(action.title)
    }
}

/// A desktop-app conversation's transcript in Tessera (dsh: its live page). Claude and Codex
/// conversations normally open straight in their app instead; see `AppModel.open`.
struct AgentPanel: View {
    @Environment(AppModel.self) private var model
    let id: String
    @State private var opened = false
    /// dsh sessions: the live dsh web page or Tessera's own transcript.
    @State private var showLive = true

    var body: some View {
        let workspace = model.workspace
        let session = workspace.agents.session(id)
        let isDsh = session?.flavor == .dsh
        let livePage = isDsh && workspace.dsh.state == .running ? workspace.dshPage : nil
        VStack(spacing: 0) {
            HStack(spacing: Style.Space.gutter) {
                if let model = session?.snapshot.model { Tag(text: model) }
                if let tokens = session?.snapshot.contextTokens { Tag(text: "\(tokens.compactTokens) ctx") }
                if let summary = session?.summary { Text(summary).font(Style.caption).foregroundStyle(Style.dim).lineLimit(1) }
                Spacer()
                if isDsh {
                    Picker("", selection: $showLive) {
                        Text("Live").tag(true)
                        Text("Transcript").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                } else {
                    if let resume = session?.resumeCommand {
                        Button {
                            model.create { $0.launch(command: resume, cwd: session?.cwd) }
                        } label: { Label("Continue in Terminal", systemImage: "terminal") }
                            .buttonStyle(.capsule)
                    }
                    // Only where the app is there to open it; the panel closes as the app comes forward.
                    if workspace.opensInApp(id) {
                        Button {
                            model.open(id)
                        } label: { Label("Open in \(session?.flavor.displayName ?? "App")", systemImage: "arrow.up.forward.app") }
                            .buttonStyle(.capsulePrimary)
                            .keyboardShortcut("o")
                    }
                }
            }
            .padding(.horizontal, Style.Space.l)
            .padding(.vertical, Style.Space.m)
            .overlay(alignment: .bottom) { Hairline() }
            if isDsh {
                DshServerStatus(server: workspace.dsh)
            }
            if isDsh, showLive, let page = livePage {
                ReparentHost(view: page.webView, focus: true)
                    .overlay { if model.privacyMode { PrivateWebCover(browser: page) } }
            } else {
                ConversationDetail(snapshot: session?.snapshot)
                    .background { EscToBoard() }
            }
        }
        .onAppear {
            guard !opened else { return }
            opened = true
            // Brings up dsh web (if needed) and selects this session in it.
            if isDsh { workspace.openNative(id, at: nil) }
        }
    }
}

// MARK: - AppKit hosts

/// Hosts a long-lived NSView (terminal, web view) that moves between containers without being recreated.
struct ReparentHost: NSViewRepresentable {
    let view: NSView
    var focus = false

    func makeNSView(context: Context) -> HostContainer {
        let container = HostContainer()
        container.adopt(view, focus: focus)
        return container
    }

    func updateNSView(_ container: HostContainer, context: Context) {
        if view.superview !== container { container.adopt(view, focus: focus) }
    }

    static func dismantleNSView(_ container: HostContainer, coordinator: ()) {
        for sub in container.subviews { sub.removeFromSuperview() }
    }

    final class HostContainer: NSView {
        private weak var hosted: NSView?
        private var focus = false

        func adopt(_ view: NSView, focus: Bool) {
            // Switching tiles while open reuses this container: evict the previous view.
            for sub in subviews where sub !== view { sub.removeFromSuperview() }
            view.removeFromSuperview()
            view.autoresizingMask = []
            addSubview(view)
            hosted = view
            needsLayout = true
            self.focus = focus
            takeFocus()
        }

        /// A panel that has just been created may reach its window only after `adopt`.
        override func viewDidMoveToWindow() { takeFocus() }

        private func takeFocus() {
            guard focus else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let hosted else { return }
                window?.makeFirstResponder(hosted)
            }
        }

        /// Only hand the hosted view a real size: a terminal given a zero frame would shrink its PTY
        /// to nothing and make the running program reflow.
        override func layout() {
            super.layout()
            guard bounds.width > 40, bounds.height > 40 else { return }
            hosted?.frame = bounds
        }
    }
}

/// Shows a live web view at desktop width, scaled down to the tile. Clicks pass through to the tile.
struct ScaledWebHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> ScaledContainer {
        let c = ScaledContainer()
        c.adopt(webView)
        return c
    }

    func updateNSView(_ container: ScaledContainer, context: Context) {
        if webView.superview !== container { container.adopt(webView) }
    }

    static func dismantleNSView(_ container: ScaledContainer, coordinator: ()) {
        for sub in container.subviews { sub.removeFromSuperview() }
    }

    final class ScaledContainer: NSView {
        static let virtualWidth: CGFloat = 1280

        func adopt(_ view: NSView) {
            view.removeFromSuperview()
            view.autoresizingMask = []
            addSubview(view)
            needsLayout = true
        }

        override func layout() {
            super.layout()
            guard frame.width > 0 else { return }
            let virtualHeight = Self.virtualWidth * frame.height / frame.width
            setBoundsSize(CGSize(width: Self.virtualWidth, height: virtualHeight))
            subviews.first?.frame = CGRect(x: 0, y: 0, width: Self.virtualWidth, height: virtualHeight)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Shown on a dsh session's panel while Tessera's dsh web server starts, or if it can't.
struct DshServerStatus: View {
    let server: DshWebServer

    var body: some View {
        switch server.state {
        case .starting:
            HStack(spacing: Style.Space.m) {
                ProgressView().controlSize(.small)
                Text("Starting dsh web…")
            }
            .font(Style.caption).foregroundStyle(Style.dim)
            .padding(.horizontal, Style.Space.l).padding(.bottom, Style.Space.s)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(Style.caption).foregroundStyle(Style.coral)
                .padding(.horizontal, Style.Space.l).padding(.bottom, Style.Space.s)
        case .stopped, .running:
            EmptyView()
        }
    }
}
