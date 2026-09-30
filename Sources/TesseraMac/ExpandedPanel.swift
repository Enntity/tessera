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
                LiveContent(info: info)
                KeyHints(hints: KeyHint.panel(info, suspended: workspace.isSuspended(id),
                                              app: workspace.opensInApp(id) ? info.flavor.displayName : nil, live: info.flavor == .dsh))
            }
        }
    }
}

/// What the keyboard does here, along the bottom of the open panel: as many of the hints as fit.
struct KeyHints: View {
    let hints: [KeyHint]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach((1...max(hints.count, 1)).reversed(), id: \.self) { count in
                HStack(spacing: Style.Space.xl) {
                    ForEach(hints.prefix(count)) { hint in
                        HStack(spacing: Style.Space.xs) {
                            Text(hint.keys).foregroundStyle(Style.dim)
                            Text(hint.label).foregroundStyle(Style.muted)
                        }
                    }
                }
                .fixedSize()
            }
        }
        .font(Style.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Style.Space.l)
        .frame(height: Style.Metrics.hints)
        .overlay(alignment: .top) { Hairline() }
    }
}

/// A tile's content, live: a terminal to type into, a page, a conversation. It is in one place at
/// a time, the open panel or (`docked`) the dock, where no key is taken that isn't typed into it.
struct LiveContent: View {
    @Environment(AppModel.self) private var model
    let info: TileInfo
    var docked = false

    var body: some View {
        let workspace = model.workspace
        switch info.kind {
        case .terminal:
            if let session = workspace.terminals[info.id] {
                host(session.view, focus: !info.activity.hasEnded)
                    .overlay {
                        // Same word blocks as the tiles; the live terminal underneath keeps the keyboard.
                        if model.privacyMode {
                            TerminalTileContent(session: session).allowsHitTesting(false)
                        }
                    }
                    .overlay { EndedOverlay(info: info, inPanel: true, keys: !docked) }
                    .padding(.horizontal, Style.Space.m)
                    .padding(.vertical, Style.Space.s)
                    .background(Style.terminalBackground)
                    // The keyboard leaves a terminal that ends while open, and returns once it runs again.
                    .onChange(of: info.activity.hasEnded) { model.restoreFocus() }
            }
        case .browser:
            if let browser = workspace.browsers[info.id] {
                host(browser.webView, focus: true)
                    // The page is back on its tile the moment the panel closes; its last
                    // still stands in here while the panel goes.
                    .background { PageStill(browser: browser) }
                    .overlay { if model.privacyMode { PrivateWebCover(browser: browser) } }
            }
        case .agentSession:
            AgentPanel(id: info.id, docked: docked, host: host)
        }
    }

    /// An open panel's terminal or page takes the keyboard as it appears. A docked one takes it
    /// when it is given it (see `AppModel.keyboardDock`), and says when a click gives or takes it.
    private func host(_ view: NSView, focus: Bool) -> ReparentHost {
        let id = info.id
        guard docked else { return ReparentHost(view: view, focus: focus) }
        return ReparentHost(view: view, focus: focus && model.keyboardDock == id, take: model.dockFocus) { [model] in
            model.dockKeyboard(id, has: $0)
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
            headerButton(model.dockAction(for: info))
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
    /// In the dock there is less room, and no key of its own: what its buttons do is in its menu.
    var docked = false
    /// Hosts the live page (see `LiveContent.host`).
    let host: (NSView, Bool) -> ReparentHost
    @State private var opened = false
    /// dsh sessions: the live dsh web page or Tessera's own transcript.
    @State private var showLive = true

    var body: some View {
        let workspace = model.workspace
        let session = workspace.agents.session(id)
        let isDsh = session?.flavor == .dsh
        // dsh web is one page: it shows the session last opened in it, and lives in that one's panel.
        let livePage = isDsh && workspace.dsh.state == .running && workspace.dshSession == id ? workspace.dshPage : nil
        VStack(spacing: 0) {
            HStack(spacing: Style.Space.gutter) {
                if let model = session?.snapshot.model { Tag(text: model) }
                if let tokens = session?.snapshot.contextTokens { Tag(text: "\(tokens.compactTokens) ctx") }
                if let summary = session?.summary {
                    Text(summary.obscured(model.privacyMode)).font(Style.caption).foregroundStyle(Style.dim).lineLimit(1)
                }
                Spacer()
                if isDsh {
                    // Choosing Live brings the page here from whichever session had it.
                    Picker("", selection: Binding(get: { showLive && livePage != nil }, set: { live in
                        showLive = live
                        if live { workspace.openNative(id, at: nil) }
                    })) {
                        Text("Live").tag(true)
                        Text("Transcript").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                } else if !docked {
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
                host(page.webView, true)
                    .overlay { if model.privacyMode { PrivateWebCover(browser: page) } }
            } else {
                ConversationDetail(snapshot: session?.snapshot)
                    .background { if !docked { EscToBoard() } }
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

/// Hosts a long-lived NSView (terminal, web view) that moves between containers without being
/// recreated. The view is in one container at a time: the one made for it last. A host it was
/// taken from never takes it back (it may still be on screen, on its way out, and two hosts that
/// each took the view whenever they were updated would hand it back and forth without end).
struct ReparentHost: NSViewRepresentable {
    let view: NSView
    /// Takes the keyboard as it comes to host the view.
    var focus = false
    /// Bumped to take the keyboard again (while `focus`).
    var take = 0
    /// Told when the view gets the keyboard, and when it loses it.
    var keyboard: ((Bool) -> Void)?

    final class Coordinator {
        var take = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> HostContainer {
        let container = HostContainer()
        container.keyboard = keyboard
        container.adopt(view, focus: focus)
        context.coordinator.take = take
        return container
    }

    func updateNSView(_ container: HostContainer, context: Context) {
        container.keyboard = keyboard
        // (A view left with no host at all is anyone's to take.)
        if container.hosted !== view || view.superview == nil {
            container.adopt(view, focus: focus)
        } else if focus, view.superview === container, context.coordinator.take != take {
            container.takeKeyboard()
        }
        context.coordinator.take = take
    }

    static func dismantleNSView(_ container: HostContainer, coordinator: Coordinator) {
        for sub in container.subviews { sub.removeFromSuperview() }
    }

    final class HostContainer: NSView {
        /// The view it was made for, which may have moved on to another host since.
        private(set) weak var hosted: NSView?
        /// That view, while it is here.
        private var held: NSView? { hosted?.superview === self ? hosted : nil }
        private var focus = false
        var keyboard: ((Bool) -> Void)?
        private var hasKeyboard = false
        private var watch: NSKeyValueObservation?

        func adopt(_ view: NSView, focus: Bool) {
            // Asked to host another view, it lets go of the one it had.
            for sub in subviews where sub !== view { sub.removeFromSuperview() }
            view.removeFromSuperview()
            view.autoresizingMask = []
            addSubview(view)
            hosted = view
            needsLayout = true
            self.focus = focus
            if focus { takeKeyboard() }
        }

        /// A panel that has just been created may reach its window only after `adopt`.
        override func viewDidMoveToWindow() {
            if focus { takeKeyboard() }
            watch = keyboard == nil ? nil : window?.observe(\.firstResponder) { [weak self] window, _ in
                MainActor.assumeIsolated { self?.keyboardMoved(to: window.firstResponder) }
            }
        }

        func takeKeyboard() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let held else { return }
                window?.makeFirstResponder(held)
            }
        }

        /// Says so when the keyboard comes to the hosted view (a click in it does that) or leaves it.
        private func keyboardMoved(to responder: NSResponder?) {
            let has = held.map { (responder as? NSView)?.isDescendant(of: $0) ?? false } ?? false
            guard has != hasKeyboard else { return }
            hasKeyboard = has
            DispatchQueue.main.async { [weak self] in self?.keyboard?(has) }
        }

        /// Only hand the hosted view a real size: a terminal given a zero frame would shrink its PTY
        /// to nothing and make the running program reflow.
        override func layout() {
            super.layout()
            guard bounds.width > 40, bounds.height > 40 else { return }
            held?.frame = bounds
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

    /// The page is the tile's from when this is made until another host is made for it (the open
    /// panel, the dock): like `ReparentHost`, it never takes the page back.
    func updateNSView(_ container: ScaledContainer, context: Context) {}

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
