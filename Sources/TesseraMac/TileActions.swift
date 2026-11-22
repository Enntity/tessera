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

    /// Dock, beside the board, or Undock.
    func dockAction(for info: TileInfo) -> TileAction {
        let docked = workspace.dock.contains(info.id)
        return TileAction(title: docked ? "Undock" : "Dock", symbol: docked ? "xmark" : Self.dockSymbol) { self.setDocked(info.id, !docked) }
    }

    /// The mark of the dock: on its button, and on a docked tile.
    static let dockSymbol = "rectangle.righthalf.inset.filled"

    /// Close — for an app conversation Hide, which looks and reads differently: nothing is stopped.
    func closeAction(for info: TileInfo) -> TileAction {
        TileAction(title: info.kind.closeLabel, symbol: info.kind.closeSymbol) { self.close(info.id) }
    }
}

/// A tile's menu, in one order for every kind, leaving out what doesn't apply: shown on right-click,
/// and as the ⋯ menu of the open panel and of a docked tile (where there is nothing left to open).
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
        let dock = model.dockAction(for: info)
        Button(dock.title, action: dock.run)
        if workspace.isWakeableTerminal(info.id) {
            // Opted out, a message for this tile always asks first, whatever the policy allows.
            Toggle("Let Agents Wake This Tile Without Asking",
                   isOn: Binding(get: { !workspace.desk.noWake.contains(info.id) },
                                 set: { workspace.desk.setNoWake(info.id, !$0) }))
        }
        Button("Rename…", action: rename)
        if let record = workspace.accord.tileRecords[info.id], record.agentAddress != nil || record.task != nil || record.client != nil {
            // What Accord knows this tile as: where agents reach it, which client enrolled it,
            // whose name it shows, and what it says it is doing.
            Menu("Accord") {
                if let agent = record.agentAddress { Button("Agent: \(agent)") {}.disabled(true) }
                if let client = record.client { Button("Client: \(client)") {}.disabled(true) }
                if let task = record.task { Button("Task: \(task)") {}.disabled(true) }
                Button("Session: \(record.address)") {}.disabled(true)
            }
        }
        ForEach(model.actions(for: info)) { action in Button(action.title, action: action.run) }
        if info.needsUser { Button(info.dismissLabel) { workspace.dismiss(info.id) } }
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

/// Rename…, for any tile: a new name at the tile's origin. Sources Tessera can name itself take it
/// at once (an empty name goes back to the origin's own); agents get it through their own rename
/// when next idle; what can't be renamed says why instead of offering a field.
struct RenamePopover: ViewModifier {
    @Environment(AppModel.self) private var model
    let info: TileInfo
    @Binding var isPresented: Bool
    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .popover(isPresented: $isPresented) {
                let support = model.workspace.renameSupport(for: info.id)
                VStack(alignment: .leading, spacing: Style.Space.xs) {
                    TextField("Title", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: Style.Metrics.nameField)
                        .disabled(support.mechanism == nil)
                        .onSubmit {
                            do { model.note = try model.workspace.rename(info.id, to: draft) }
                            catch { model.note = error.localizedDescription }
                            isPresented = false
                        }
                    if case .unsupported(let reason) = support {
                        Text(reason).font(Style.ui(.label)).foregroundStyle(Style.dim)
                            .frame(width: Style.Metrics.nameField, alignment: .leading)
                    }
                }
                .padding(Style.Space.gutter)
                .onAppear { draft = info.title }
            }
            .onChange(of: isPresented) { _, shown in if !shown { model.restoreFocus() } }
    }
}
