import AppKit
import SwiftUI
import TesseraHost
import TesseraKit

@main
struct TesseraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Tessera", id: "board") {
            FillProposal { DashboardView() }
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(.dark)
                .onAppear { model.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1680, height: 1000)
        .commands { BoardCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched as a bare SwiftPM binary during development, AppKit needs telling we're a real app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// App-wide state the views share: the workspace, the remote server, and transient UI state. Every
/// open, new tile, close and hand-off of the keyboard goes through here, whoever asks for it
/// (a click, a shortcut, the palette, a notification, the phone).
@Observable
@MainActor
final class AppModel {
    let workspace = Workspace()
    @ObservationIgnored lazy var server = HostServer(workspace: workspace, open: { [weak self] in self?.open($0) },
                                                     close: { [weak self] in self?.close($0) })
    var showPalette = false
    var showSidebar = true
    /// Screenshot-safe: terminals, conversations and pages stay lively but unreadable.
    var privacyMode = Preferences.store.bool(forKey: "tessera.privacy") {
        didSet { Preferences.store.set(privacyMode, forKey: "tessera.privacy") }
    }
    /// The "connect an account" sheet in Settings; the sidebar's + opens it directly.
    var showAddAccount = false
    /// The "watch a machine" sheet in Settings → Machines.
    var showAddMachine = false
    var paletteMode: PaletteMode = .all
    /// Bumped to hand the keyboard to the board (see `restoreFocus`).
    private(set) var boardFocus = 0
    /// Bumped to put the cursor in the open web tile's address field (⌘L).
    private(set) var addressFocus = 0
    /// The last close, while its toast offers to undo it.
    private(set) var closedToast: ClosedToast?
    /// The closes Edit ▸ Undo can still undo, the latest last.
    private var undoMarks: [UndoMark] = []
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var notifier: AttentionNotifier?

    enum PaletteMode { case all, url }

    func start() {
        guard !started else { return }
        started = true
        if handOffToRunningCopy() { return }
        workspace.onLink = { [weak self] url in self?.create { $0.openBrowser(url.absoluteString) } }
        workspace.start()
        reportUnreadableFiles()
        if Preferences.store.bool(forKey: "tessera.remoteEnabled") { server.start() }
        // Record every terminal's folder and conversation, then stop them, so next launch resumes.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.workspace.prepareForQuit() }
        }
        // UNUserNotificationCenter requires an app bundle; a bare `swift run` binary goes without.
        if Bundle.main.bundleIdentifier != nil, !Preferences.isDevelopmentCopy {
            notifier = AttentionNotifier { [weak self] id in self?.open(id) }
        }
        // The Dock badge and alerts follow the board's attention state.
        observe({ [weak self] in self?.workspace.state }) { [weak self] _ in self?.attentionChanged() }
        #if DEBUG
        startDebugRun()
        #endif
    }

    func setRemote(_ on: Bool) {
        Preferences.store.set(on, forKey: "tessera.remoteEnabled")
        on ? server.start() : server.stop()
    }

    private func attentionChanged() {
        let waiting = workspace.state.needsInput.count
        let badge = waiting > 0 ? "\(waiting)" : nil
        if NSApp.dockTile.badgeLabel != badge { NSApp.dockTile.badgeLabel = badge }
        notifier?.update(with: workspace.allTiles)
    }

    // MARK: Open, create, close

    /// One user action is one SwiftUI transaction. Changes split across two (say a plain one, then
    /// an animated one) make SwiftUI redraw in between, and a view redrawn then can miss the second.
    private func act(_ animation: Animation, _ change: () -> Void) {
        withAnimation(animation, change)
        restoreFocus()
    }

    /// Opens a tile: in place on the board, or for a Claude or Codex conversation, straight in its
    /// app, landing where the opened tile would have. `inApp: false` shows such a conversation's
    /// transcript in Tessera instead.
    func open(_ id: String, inApp: Bool = true) {
        act(Style.Motion.zoom) { workspace.open(id, inApp: inApp, nativeAt: appRect(for: id)) }
    }

    /// Where the app's window goes when tile `id` opens in its app (AppKit screen coordinates).
    private func appRect(for id: String) -> CGRect? {
        openedRect(from: tileFrame(id)).flatMap(screenRect(fromWindow:))
    }

    /// Every way of starting a tile ends here: `make` starts it, and it opens at once.
    func create(_ make: (Workspace) -> String?) {
        act(Style.Motion.zoom) { if let id = make(workspace) { workspace.open(id) } }
    }

    /// Back to the board; the tile stays selected.
    func collapse() {
        act(Style.Motion.zoom) { workspace.collapse() }
    }

    /// Closes tiles (an app conversation: hides it), and offers the way back: a toast, and Undo on
    /// the Edit menu (⌘Z). Every close comes through here.
    func close(_ ids: [String]) {
        act(Style.Motion.standard) {
            let closed = ids.compactMap(workspace.close)
            guard let first = closed.first else { return }
            let many = first.kind == .agentSession ? "conversations" : "tiles"
            closedToast = ClosedToast(ids: closed.map(\.id), text: first.kind.closedLabel + " "
                                      + (closed.count == 1 ? first.title.preview(40) : "\(closed.count) \(many)"))
            guard let undo = window?.undoManager else { return }
            let mark = UndoMark(ids: closed.map(\.id), name: first.kind == .agentSession ? "Hide Conversation" : "Close Tile")
            undoMarks.append(mark)
            // Each close is an Undo of its own, however it arrives (a key, a menu, the phone): AppKit
            // would group it with whatever else is registered before the next event.
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            undo.registerUndo(withTarget: mark) { [weak self] mark in self?.reopen(mark.ids) }
            undo.setActionName(mark.name)
            undo.endUndoGrouping()
            undo.groupsByEvent = true
            pruneUndo()
        }
    }

    func close(_ id: String) { close([id]) }

    /// Brings closed tiles and hidden conversations back to their places (Undo, the toast, ⌘K's
    /// "Reopen …", which also opens the tile).
    func reopen(_ ids: [String], open: Bool = false) {
        act(Style.Motion.zoom) {
            let back = ids.filter(workspace.reopen)
            if open, let id = back.first { workspace.open(id, nativeAt: appRect(for: id)) }
            if let toast = closedToast, !toast.ids.contains(where: isClosed) { closedToast = nil }
            pruneUndo()
        }
    }

    private func isClosed(_ id: String) -> Bool { workspace.recentlyClosed.tiles.contains { $0.id == id } }

    /// An Undo with nothing left to bring back (its tiles are back already, or closed too long ago
    /// to still be kept) leaves the Edit menu.
    private func pruneUndo() {
        undoMarks.removeAll { mark in
            guard !mark.ids.contains(where: isClosed) else { return false }
            window?.undoManager?.removeAllActions(withTarget: mark)
            return true
        }
    }

    /// Edit ▸ Undo (⌘Z), `key` being the window with the keyboard. Whatever has the keyboard undoes
    /// its own typing, and otherwise its window undoes the last close. But SwiftUI's stand-in for
    /// the focused board has no undo manager, which leaves the window's own Undo dead: then the
    /// close is undone here.
    func undo(key: NSWindow?) {
        let responder = key?.firstResponder
        if key === window, responder?.undoManager == nil {
            window?.undoManager?.undo()
        } else {
            responder?.tryToPerform(Selector(("undo:")), with: nil)
        }
    }

    /// What Edit ▸ Undo is called: after the last close still to undo.
    var undoTitle: String { "Undo" + (undoMarks.last.map { " " + $0.name } ?? "") }

    /// The toast goes after a few seconds; Undo stays on the Edit menu.
    func dismiss(_ toast: ClosedToast) {
        if closedToast == toast { withAnimation(Style.Motion.standard) { closedToast = nil } }
    }

    /// A command on many tiles at once, from ⌘K or the Board menu.
    func run(_ command: BoardCommand) {
        let ids = workspace.targets(of: command)
        switch command {
        case .closeExited, .hideIdle: close(ids)
        case .showHidden: reopen(ids)
        case .markAllSeen: ids.forEach(workspace.acknowledge)
        case .restartFailed: ids.forEach(workspace.restart)
        case .shutDownAll: ids.forEach(workspace.shutDown)
        case .resumeAll: ids.forEach(workspace.resume)
        }
    }

    /// Tab clicks, ⌘1…9 and new tabs change the board itself, so an open panel closes first.
    func onBoard(_ change: (Workspace) -> Void) {
        act(Style.Motion.standard) {
            workspace.collapse()
            change(workspace)
        }
    }

    /// ⇧⌘P and the eye in the top bar.
    func togglePrivacy() {
        act(Style.Motion.standard) { privacyMode.toggle() }
    }

    /// ⌘\ and its button in the top bar.
    func toggleSidebar() {
        act(Style.Motion.standard) { showSidebar.toggle() }
    }

    /// Puts the keyboard where the user is, after anything that took it away (the palette, a
    /// popover, a panel closing): in the open tile's terminal or page, else on the board.
    func restoreFocus() {
        DispatchQueue.main.async { [self] in
            guard !showPalette, let window else { return }
            guard let id = workspace.expandedId else {
                window.makeFirstResponder(window.contentView)
                boardFocus &+= 1
                return
            }
            let view: NSView?
            if let terminal = workspace.terminals[id] {
                // A terminal that isn't running takes no typing: the window keeps the keys, so ⏎
                // and Esc reach its Resume / Restart panel.
                view = terminal.isRunning ? terminal.view : nil
            } else {
                view = workspace.browsers[id]?.webView ?? workspace.dshPage?.webView
            }
            window.makeFirstResponder(view?.window === window ? view : nil)
        }
    }

    /// ⌘W closes what is in front: another window (Settings), the palette, the open panel (back to
    /// the board), and on the board itself the selected tile. `key` is the window with the keyboard.
    func closeFront(key: NSWindow?) {
        if let key, key !== window { return key.performClose(nil) }
        if showPalette {
            showPalette = false
        } else if workspace.expandedId != nil {
            collapse()
        } else if let id = workspace.selectedId {
            close(id)
        }
    }

    /// Arrow keys and ⌘[ ⌘]. On the board the selection moves; with a panel open the open tile
    /// changes in place and never leaves Tessera (a Claude or Codex conversation shows its transcript).
    func move(_ step: GridMove) {
        let ids = workspace.visibleIds
        let layout = BoardView.grid(count: ids.count, in: boardFrame?.size ?? .zero)
        guard let i = layout.index(moving: step, from: workspace.selectedId.flatMap(ids.firstIndex(of:)), count: ids.count) else { return }
        if workspace.expandedId != nil { open(ids[i], inApp: false) } else { workspace.select(ids[i]) }
    }

    /// The HUD counters and ⌘J: opens the next of `ids` in the order they are visited.
    func jump(to ids: Set<String>) {
        if let id = workspace.next(in: ids) { open(id) }
    }

    /// ⌃Tab: back to the tile opened before this one, and again to return. Like ⌘[ ⌘], it stays in
    /// Tessera while a panel is open.
    func openPrevious() {
        if let id = workspace.previousTile { open(id, inApp: workspace.expandedId == nil) }
    }

    /// The web tile that is open, if one is.
    var openPage: BrowserSession? { workspace.expandedId.flatMap { workspace.browsers[$0] } }

    /// ⌘L: the open web tile's address field, or (also from the palette, which covers that field)
    /// a new web tile.
    func openLocation() {
        if openPage != nil, !showPalette {
            addressFocus &+= 1
        } else {
            paletteMode = .url
            showPalette = true
        }
    }

    // MARK: Geometry

    /// Converts a window-space rect (top-left origin) to AppKit screen coordinates.
    func screenRect(fromWindow rect: CGRect) -> CGRect? {
        guard let window, let content = window.contentView else { return nil }
        let flipped = NSRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        return window.convertToScreen(flipped)
    }

    /// Set by the board: its rectangle in the window, and how far it is scrolled.
    @ObservationIgnored var boardFrame: CGRect?
    @ObservationIgnored var boardScroll: CGFloat = 0

    /// Where tile `id` sits on the board right now (window coordinates), for opening in place.
    func tileFrame(_ id: String) -> CGRect? {
        let ids = workspace.visibleIds
        guard let board = boardFrame, let index = ids.firstIndex(of: id) else { return nil }
        let layout = BoardView.grid(count: ids.count, in: board.size)
        let origin = layout.origin(of: index, in: board.size)
        return CGRect(x: board.minX + origin.x, y: board.minY + origin.y - boardScroll,
                      width: layout.tileSize.width, height: layout.tileSize.height)
    }

    /// Where a tile opened from `source` settles (window coordinates, top-left origin).
    func openedRect(from source: CGRect?) -> CGRect? {
        boardFrame.map { ExpandedPanel.target(from: source, board: $0) }
    }

    /// Starts a conversation in the Claude or Codex app and lands its window where an opened tile
    /// sits, so the eye doesn't leave the board.
    func newAppConversation(_ app: AgentApp, prompt: String? = nil) {
        workspace.newAppConversation(app, folder: contextDirectory, prompt: prompt,
                                     placeAt: openedRect(from: nil).flatMap(screenRect(fromWindow:)))
    }

    /// New tiles start where the selected terminal is working.
    var contextDirectory: String {
        if let sel = workspace.selectedId, let t = workspace.terminals[sel] { return t.cwd }
        return workspace.defaultDirectory
    }
}

/// What the toast says after a close, and the tiles its Undo brings back.
struct ClosedToast: Equatable {
    let ids: [String]
    let text: String
}

/// The target of one close's Undo on the Edit menu, so that when its tiles come back some other
/// way (the toast, ⌘K) that Undo can be taken off the menu.
private final class UndoMark {
    let ids: [String]
    let name: String

    init(ids: [String], name: String) {
        self.ids = ids
        self.name = name
    }
}
