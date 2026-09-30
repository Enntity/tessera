import SwiftUI
import TesseraHost
import TesseraKit

/// The File and Board menus: every shortcut the app has.
struct BoardCommands: Commands {
    let model: AppModel

    var body: some Commands {
        let workspace = model.workspace
        CommandGroup(replacing: .newItem) {
            Button("New Shell") { model.create { $0.launch(command: nil, cwd: model.contextDirectory) } }
                .keyboardShortcut("t")
            Button("New Claude Code") { model.create { $0.launch(command: "claude", cwd: model.contextDirectory) } }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("New Codex") { model.create { $0.launch(command: "codex", cwd: model.contextDirectory) } }
                .keyboardShortcut("t", modifiers: [.command, .option])
            ForEach(workspace.installedApps, id: \.self) { app in
                Button(app.newLabel) { model.newAppConversation(app) }
            }
            Button(model.openPage == nil ? "Open Web Tile…" : "Edit Address") { model.openLocation() }
                .keyboardShortcut("l")
            Divider()
            Button("Close") { model.closeFront(key: NSApp.keyWindow) }
                .keyboardShortcut("w")
        }
        // The system's Undo can't act while the board has the keyboard (see `AppModel.undo`).
        CommandGroup(replacing: .undoRedo) {
            Button(model.undoTitle) { model.undo(key: NSApp.keyWindow) }
                .keyboardShortcut("z")
            Button("Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        // The View menu: the columns beside the board.
        CommandGroup(replacing: .sidebar) {
            Button(model.showLane ? "Hide Needs You Lane" : "Show Needs You Lane") { model.toggleLane() }
                .keyboardShortcut("\\", modifiers: [.command, .option])
            Button(model.showSidebar ? "Hide Accounts" : "Show Accounts") { model.toggleSidebar() }
                .keyboardShortcut("\\")
            Divider()
            // How small tiles get before the board scrolls.
            Button("Larger Tiles") { model.stepDensity(by: 1) }
                .keyboardShortcut("=")
            Button("Smaller Tiles") { model.stepDensity(by: -1) }
                .keyboardShortcut("-")
            Button("Standard Tile Size") { model.stepDensity(by: nil) }
                .keyboardShortcut("0")
        }
        CommandMenu("Board") {
            Button("Command Palette") {
                // From the ⌘L palette, ⌘K goes to the full one rather than closing it.
                model.showPalette = !(model.showPalette && model.paletteMode == .all)
                model.paletteMode = .all
            }
            .keyboardShortcut("k")
            Button("Open / Close Tile") { model.toggleOpen() }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Dock / Undock Tile") {
                if let id = model.dockTarget { model.setDocked(id, !workspace.dock.contains(id)) }
            }
            .keyboardShortcut("d")
            Button("Next Tile Needing Me") { model.jump(to: workspace.state.needsUser) }
                .keyboardShortcut("j")
            Button("Next Tile") { model.move(.next) }
                .keyboardShortcut("]")
            Button("Previous Tile") { model.move(.previous) }
                .keyboardShortcut("[")
            Button("Last Opened Tile") { model.openPrevious() }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Filter") { model.beginFilter() }
                .keyboardShortcut("f")
            Divider()
            Button(model.privacyMode ? "Turn Off Privacy Mode" : "Privacy Mode") { model.togglePrivacy() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            // These act on the tab being viewed; the two below them on every terminal.
            ForEach(BoardCommand.allCases.filter { !$0.everyTab }) { command in
                Button(command.title) { model.run(command) }
            }
            Divider()
            Button(BoardCommand.shutDownAll.title) { model.run(.shutDownAll) }
                .keyboardShortcut("w", modifiers: [.command, .option, .shift])
            Button(BoardCommand.resumeAll.title) { model.run(.resumeAll) }
                .keyboardShortcut("r", modifiers: [.command, .option, .shift])
            Divider()
            Button("Show All") { model.onBoard { $0.filter = .all } }.keyboardShortcut("1")
            Button(workspace.query.chips.contains(.needsYou) ? "Show Everything Again" : "Show Only What Needs You") { model.toggle(.needsYou) }
                .keyboardShortcut("2")
            ForEach(Array(workspace.groups.list.prefix(7).enumerated()), id: \.element.id) { i, group in
                Button("Show \(group.name)") { model.onBoard { $0.filter = .group(group.id) } }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 3)")))
            }
        }
    }
}
