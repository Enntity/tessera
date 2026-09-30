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
            Button("Close") { model.closeFront() }
                .keyboardShortcut("w")
        }
        CommandMenu("Board") {
            Button("Command Palette") {
                // From the ⌘L palette, ⌘K goes to the full one rather than closing it.
                model.showPalette = !(model.showPalette && model.paletteMode == .all)
                model.paletteMode = .all
            }
            .keyboardShortcut("k")
            Button("Open / Close Tile") {
                if workspace.expandedId != nil { model.collapse() } else if let id = workspace.selectedId { model.open(id) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            Button("Next Tile Needing Me") { model.jump(to: workspace.state.needsUser) }
                .keyboardShortcut("j")
            Button("Next Tile") { model.move(.next) }
                .keyboardShortcut("]")
            Button("Previous Tile") { model.move(.previous) }
                .keyboardShortcut("[")
            Divider()
            Button(model.privacyMode ? "Turn Off Privacy Mode" : "Privacy Mode") {
                withAnimation(.easeInOut(duration: 0.25)) { model.privacyMode.toggle() }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Button(model.showSidebar ? "Hide Accounts" : "Show Accounts") {
                withAnimation(.spring(duration: 0.3)) { model.showSidebar.toggle() }
            }
            .keyboardShortcut("\\")
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
            Button("Show Needs You") { model.onBoard { $0.filter = .attention } }.keyboardShortcut("2")
            ForEach(Array(workspace.groups.list.prefix(7).enumerated()), id: \.element.id) { i, group in
                Button("Show \(group.name)") { model.onBoard { $0.filter = .group(group.id) } }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 3)")))
            }
        }
    }
}
