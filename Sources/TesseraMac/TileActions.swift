import SwiftUI
import TesseraHost
import TesseraKit

/// Something that can be done to a tile: the same list feeds its hover buttons, its right-click
/// menu, and the open panel's header and ⋯ menu, so they can't drift apart.
struct TileAction: Identifiable {
    let title: String
    let symbol: String
    let run: () -> Void

    var id: String { title }
}

extension AppModel {
    /// What a tile's kind adds, as it is now: a terminal's Shut Down / Resume / Restart, a page's
    /// Reload and Open in Browser.
    func actions(for info: TileInfo) -> [TileAction] {
        let id = info.id
        switch info.kind {
        case .terminal:
            if workspace.isSuspended(id) { return [TileAction(title: "Resume", symbol: "play.fill") { self.workspace.resume(id) }] }
            let restart = TileAction(title: "Restart", symbol: "arrow.clockwise") { self.workspace.restart(id) }
            // Exited or failed, there is nothing left to shut down.
            return info.activity.hasEnded ? [restart] : [TileAction(title: "Shut Down", symbol: "power") { self.workspace.shutDown(id) }, restart]
        case .browser:
            return [TileAction(title: "Reload", symbol: "arrow.clockwise") { self.workspace.restart(id) },
                    TileAction(title: "Open in Browser", symbol: "safari") {
                        if let url = self.workspace.browsers[id]?.url { NSWorkspace.shared.open(url) }
                    }]
        case .agentSession:
            return []
        }
    }

    /// Close — for an app conversation Hide, which looks and reads differently: nothing is stopped.
    func closeAction(for info: TileInfo) -> TileAction {
        TileAction(title: info.kind.closeLabel, symbol: info.kind.closeSymbol) { self.close(info.id) }
    }
}

/// A tile's menu, in one order for every kind, leaving out what doesn't apply: shown on right-click,
/// and as the open panel's ⋯ menu (where there is nothing left to open).
struct TileMenu: View {
    @Environment(AppModel.self) private var model
    let info: TileInfo
    var inPanel = false
    let rename: () -> Void

    var body: some View {
        let workspace = model.workspace
        if workspace.opensInApp(info.id) {
            Button("Open in \(info.flavor.displayName)") { model.open(info.id) }
            if !inPanel { Button("Show Transcript") { model.open(info.id, inApp: false) } }
        } else if !inPanel {
            Button("Open") { model.open(info.id) }
        }
        if let session = workspace.agents.session(info.id), let resume = session.resumeCommand {
            Button("Continue in Terminal") { model.create { $0.launch(command: resume, cwd: session.cwd) } }
        }
        Button("Rename…", action: rename)
        ForEach(model.actions(for: info)) { action in Button(action.title, action: action.run) }
        if info.attention { Button("Mark as Seen") { workspace.acknowledge(info.id) } }
        Menu("Move to Tab") {
            let current = workspace.groups.group(of: info.id)?.id
            ForEach(workspace.groups.list) { group in
                Button(group.name) { withAnimation(Style.Motion.standard) { workspace.move(tile: info.id, toGroup: group.id) } }
                    .disabled(group.id == current)
            }
            if !workspace.groups.list.isEmpty { Divider() }
            Button("New Tab with This Tile") {
                withAnimation(Style.Motion.standard) { _ = workspace.createGroup(named: Self.suggestedTabName(info), with: info.id) }
            }
            if current != nil {
                Button("Remove from Tab") { withAnimation(Style.Motion.standard) { workspace.move(tile: info.id, toGroup: nil) } }
            }
        }
        Divider()
        Button(info.kind.closeLabel, role: .destructive) { model.close(info.id) }
    }

    /// A new tab is named after the tile's folder or site; rename it from the tab's menu.
    static func suggestedTabName(_ info: TileInfo) -> String {
        let last = (info.subtitle as NSString).lastPathComponent
        return last.isEmpty || last == "~" ? info.title : last
    }
}

/// Rename…, for any tile: a name of the user's own, kept with the board. An empty name goes back
/// to the tile's own title.
struct RenamePopover: ViewModifier {
    @Environment(AppModel.self) private var model
    let info: TileInfo
    @Binding var isPresented: Bool
    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .popover(isPresented: $isPresented) {
                TextField("Title", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .padding(Style.Space.gutter)
                    .onAppear { draft = info.title }
                    .onSubmit {
                        model.workspace.rename(info.id, to: draft)
                        isPresented = false
                    }
            }
            .onChange(of: isPresented) { _, shown in if !shown { model.restoreFocus() } }
    }
}
