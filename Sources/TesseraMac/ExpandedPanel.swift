import AppKit
import SwiftUI
import TesseraHost
import TesseraKit
import WebKit

/// The opened tile. It grows out of the tile's own rectangle and settles centred on it, so the
/// user's eyes never have to travel.
struct ExpandedPanel: View {
    @Environment(AppModel.self) private var model
    let id: String
    let board: CGRect
    let source: CGRect?
    @State private var settled = false

    var body: some View {
        let area = board.insetBy(dx: 10, dy: 6)
        let origin = source ?? CGRect(x: area.midX - 150, y: area.midY - 100, width: 300, height: 200)
        let preferred = CGSize(width: max(area.width * 0.8, min(area.width, 900)), height: area.height * 0.92)
        let target = GridLayout.expandedFrame(from: origin, in: area, preferred: preferred)
        let scaleX = settled ? 1 : origin.width / target.width
        let scaleY = settled ? 1 : origin.height / target.height
        let at = settled ? target.origin : origin.origin

        ZStack(alignment: .topLeading) {
            Color.black.opacity(settled ? 0.5 : 0)
                .contentShape(Rectangle())
                .onTapGesture { model.collapse() }
            PanelContent(id: id, frame: target)
                .frame(width: target.width, height: target.height)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Style.ink.opacity(0.18)))
                .shadow(color: .black.opacity(0.6), radius: 40, y: 18)
                .scaleEffect(x: scaleX, y: scaleY, anchor: .topLeading)
                .offset(x: at.x - board.minX, y: at.y - board.minY)
                .opacity(settled ? 1 : 0.3)
        }
        .onAppear {
            model.expandedFrame = target
            withAnimation(.spring(duration: 0.36, bounce: 0.1)) { settled = true }
        }
        .onChange(of: id) { _, _ in
            settled = false
            withAnimation(.spring(duration: 0.36, bounce: 0.1)) { settled = true }
        }
    }
}

struct PanelContent: View {
    @Environment(AppModel.self) private var model
    let id: String
    let frame: CGRect

    var body: some View {
        let workspace = model.workspace
        if let info = workspace.info(id) {
            VStack(spacing: 0) {
                PanelHeader(info: info, frame: frame)
                switch info.kind {
                case .terminal:
                    if let session = workspace.terminals[id] {
                        ReparentHost(view: session.view, focus: true)
                            .overlay {
                                // Same minimap look as the tiles; the live terminal underneath keeps the keyboard.
                                if model.privacyMode {
                                    TerminalTileContent(session: session).allowsHitTesting(false)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Style.terminalBackground)
                    }
                case .browser:
                    if let browser = workspace.browsers[id] {
                        ReparentHost(view: browser.webView, focus: true)
                            .overlay { if model.privacyMode { PrivateWebCover(browser: browser) } }
                    }
                case .agentSession:
                    AgentPanel(id: id, frame: frame)
                }
            }
            .background(Style.deck)
        }
    }
}

struct PanelHeader: View {
    @Environment(AppModel.self) private var model
    let info: TileInfo
    let frame: CGRect
    @State private var urlText = ""

    var body: some View {
        let workspace = model.workspace
        HStack(spacing: 10) {
            Image(systemName: info.flavor.symbol).foregroundStyle(Style.accent(info.flavor))
            if info.kind == .browser, let browser = workspace.browsers[info.id] {
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
                Button { browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
                TextField("URL", text: $urlText)
                    .textFieldStyle(.plain)
                    .font(Style.mono(12))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Style.glass, in: RoundedRectangle(cornerRadius: 6))
                    .onAppear { urlText = info.url ?? "" }
                    .onChange(of: info.url) { _, u in urlText = u ?? "" }
                    .onSubmit {
                        if let url = WebAddress.normalize(urlText) { browser.load(url) }
                    }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.title).font(Style.ui(13, .semibold)).foregroundStyle(Style.ink).lineLimit(1)
                    Text(info.subtitle).font(Style.mono(10)).foregroundStyle(Style.dim).lineLimit(1)
                }
                Spacer()
            }
            StatePill(activity: info.activity)
            if let cols = info.cols, let rows = info.rows {
                Text("\(cols)×\(rows)").font(Style.mono(10)).foregroundStyle(Style.faint)
            }
            if info.kind == .terminal {
                if workspace.terminals[info.id]?.isSuspended == true {
                    headerButton("play.fill", "Resume") { workspace.resume(info.id) }
                } else {
                    headerButton("power", "Shut down (keeps the conversation for Resume)") { workspace.shutDown(info.id) }
                    headerButton("arrow.clockwise", "Restart") { workspace.restart(info.id) }
                }
            }
            if info.kind == .browser, let url = workspace.browsers[info.id]?.url {
                headerButton("safari", "Open in default browser") { NSWorkspace.shared.open(url) }
            }
            headerButton("xmark.circle", info.kind == .agentSession ? "Hide tile" : "Close tile") {
                workspace.close(info.id)
            }
            headerButton("arrow.down.right.and.arrow.up.left", "Back to board (⌘⏎)") { model.collapse() }
        }
        .foregroundStyle(Style.dim)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Style.glass)
        .overlay(alignment: .bottom) { Rectangle().fill(Style.hairline).frame(height: 1) }
    }

    private func headerButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13)) }
            .buttonStyle(.plain)
            .help(help)
    }
}

/// A desktop-app conversation opened: our own readable transcript, with the real app snapped on
/// top of it at exactly this rectangle.
struct AgentPanel: View {
    @Environment(AppModel.self) private var model
    let id: String
    let frame: CGRect
    @State private var opened = false

    var body: some View {
        let workspace = model.workspace
        let session = workspace.agents.sessions[id]
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let model = session?.snapshot.model { Tag(text: model) }
                if let tokens = session?.snapshot.contextTokens { Tag(text: "\(tokens.compactTokens) ctx") }
                if let summary = session?.summary { Text(summary).font(Style.mono(10)).foregroundStyle(Style.dim).lineLimit(1) }
                Spacer()
                if let resume = session?.resumeCommand {
                    Button {
                        workspace.launch(command: resume, cwd: session?.cwd)
                        model.collapse()
                    } label: { Label("Continue in Terminal", systemImage: "terminal") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button {
                    openNative()
                } label: { Label("Open in \(session?.flavor.displayName ?? "App")", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.borderedProminent)
                    .tint(Style.accent(session?.flavor ?? .claudeDesktop).opacity(0.8))
                    .controlSize(.small)
                    .keyboardShortcut("o")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            if session?.flavor == .dsh {
                DshServerStatus(server: workspace.dsh)
            }
            ConversationDetail(snapshot: session?.snapshot, flavor: session?.flavor ?? .claudeDesktop)
        }
        .onAppear {
            guard workspace.placeNativeWindows, !opened else { return }
            opened = true
            // Let the zoom finish first so the app lands on a settled rectangle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openNative() }
        }
    }

    private func openNative() {
        model.workspace.openNative(id, at: model.screenRect(fromWindow: frame))
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

        func adopt(_ view: NSView, focus: Bool) {
            // Switching tiles while open reuses this container: evict the previous view.
            for sub in subviews where sub !== view { sub.removeFromSuperview() }
            view.removeFromSuperview()
            view.autoresizingMask = []
            addSubview(view)
            hosted = view
            needsLayout = true
            if focus {
                DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(view) }
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
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Starting dsh web…").font(Style.mono(11)).foregroundStyle(Style.dim)
            }
            .padding(.horizontal, 14).padding(.bottom, 6)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(Style.mono(11)).foregroundStyle(Style.amber)
                .padding(.horizontal, 14).padding(.bottom, 6)
        case .stopped, .running:
            EmptyView()
        }
    }
}
