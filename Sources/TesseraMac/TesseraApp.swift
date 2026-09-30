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
            DashboardView()
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

/// App-wide state the views share: the workspace, the remote server, and transient UI state.
@Observable
@MainActor
final class AppModel {
    let workspace = Workspace()
    @ObservationIgnored lazy var server = HostServer(workspace: workspace)
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
    /// Where each visible tile is, in window coordinates; used to open panels and native windows in place.
    @ObservationIgnored var tileFrames: [String: CGRect] = [:]
    var expandedFrame: CGRect?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var notifier: AttentionNotifier?

    enum PaletteMode { case all, url }

    func start() {
        guard !started else { return }
        started = true
        workspace.start()
        reportUnreadableFiles()
        if Preferences.store.bool(forKey: "tessera.remoteEnabled") { server.start() }
        // Record every terminal's folder and conversation, then stop them, so next launch resumes.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.workspace.prepareForQuit() }
        }
        // UNUserNotificationCenter requires an app bundle; a bare `swift run` binary goes without.
        if Bundle.main.bundleIdentifier != nil {
            notifier = AttentionNotifier { [weak self] id in self?.open(id) }
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateDockBadge()
                self.notifier?.update(with: self.workspace.allTiles)
            }
        }
        #if DEBUG
        if let actions = ProcessInfo.processInfo.environment["TESSERA_DEBUG_ACTIONS"] {
            runDebugActions(actions.split(separator: ";").map(String.init))
        }
        if let path = ProcessInfo.processInfo.environment["TESSERA_SNAPSHOT"] {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.writeSnapshot(to: path) }
            }
        }
        #endif
    }

    #if DEBUG
    /// Development aid: `launch=<cmd>`, `url=<url>`, `open=terminal|app|web`, `palette`, `remote`, `machine=<ssh host>`, `pairurl=<file>`,
    /// `filter=<name>`, `wait=<s>`, separated by `;`. Only read from the TESSERA_DEBUG_ACTIONS environment variable.
    private func runDebugActions(_ actions: [String], after delay: Double = 2) {
        guard let first = actions.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            let parts = first.split(separator: "=", maxSplits: 1).map(String.init)
            var next = 1.0
            switch parts[0] {
            case "launch": workspace.launch(command: parts.count > 1 ? parts[1] : nil)
            case "url": if parts.count > 1 { workspace.openBrowser(parts[1]) }
            case "palette": showPalette = true
            case "privacy": privacyMode = true
            case "responder":
                let r = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                if parts.count > 1 { try? r.write(toFile: parts[1], atomically: true, encoding: .utf8) }
            case "openlast":
                if let id = workspace.selectedId { open(id) }
            case "key":
                // Synthesizes key presses (up,down,left,right,esc) into the window.
                let keys: [String: (UInt16, Int)] = ["up": (126, NSUpArrowFunctionKey), "down": (125, NSDownArrowFunctionKey),
                                                     "left": (123, NSLeftArrowFunctionKey), "right": (124, NSRightArrowFunctionKey),
                                                     "esc": (53, 0x1B)]
                for name in (parts.count > 1 ? parts[1] : "").split(separator: ",").map(String.init) {
                    guard let (code, char) = keys[name], let window else { continue }
                    let chars = String(UnicodeScalar(UInt32(char)).map(Character.init) ?? " ")
                    let flags: NSEvent.ModifierFlags = char > 0xF000 ? [.function, .numericPad] : []
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, characters: chars,
                                                    charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                            // Straight to the window: works while the test copy is in the background.
                            window.sendEvent(e)
                        }
                    }
                }
            case "opendsh":
                if let tile = workspace.allTiles.first(where: { $0.flavor == .dsh }) { open(tile.id) }
            case "machine": if parts.count > 1 { workspace.machines.add(host: parts[1], name: nil) }
            case "remote": server.start() // not persisted: normal launches keep the user's setting
            case "pairurl":
                if parts.count > 1 { try? server.pairingURL?.absoluteString.write(toFile: parts[1], atomically: true, encoding: .utf8) }
            case "filter": workspace.filter = parts.count > 1 && parts[1] == "attention" ? .attention : .all
            case "tab":
                if parts.count > 1 {
                    let id = workspace.createGroup(named: parts[1])
                    for tile in workspace.allTiles.prefix(2) { workspace.move(tile: tile.id, toGroup: id) }
                }
            case "wait": next = Double(parts.count > 1 ? parts[1] : "1") ?? 1
            case "open":
                let kind: TileKind = parts.count > 1 ? (parts[1] == "app" ? .agentSession : parts[1] == "web" ? .browser : .terminal) : .terminal
                if let tile = workspace.visibleTiles.first(where: { $0.kind == kind }) { open(tile.id) }
            default: break
            }
            runDebugActions(Array(actions.dropFirst()), after: next)
        }
    }

    /// Development aid: captures the board window to a PNG so layout can be checked without screen capture rights.
    /// Apps may always capture their own windows; the symbol is looked up dynamically because the SDK hides it.
    private func writeSnapshot(to path: String) {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let window, let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let capture = unsafeBitCast(sym, to: Capture.self)
        // .null rect = window bounds; option 8 = including window; 1 = ignore framing.
        guard let image = capture(.null, 8, UInt32(window.windowNumber), 1)?.takeRetainedValue() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #endif

    func setRemote(_ on: Bool) {
        Preferences.store.set(on, forKey: "tessera.remoteEnabled")
        on ? server.start() : server.stop()
    }

    private func updateDockBadge() {
        let waiting = workspace.counts.needsInput
        NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil
    }

    /// Converts a window-space rect (top-left origin) to AppKit screen coordinates.
    func screenRect(fromWindow rect: CGRect) -> CGRect? {
        guard let window, let content = window.contentView else { return nil }
        let flipped = NSRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        return window.convertToScreen(flipped)
    }

    /// Opens a tile: in place on the board, or for a Claude or Codex conversation, straight in its
    /// app, landing where the opened tile would have.
    func open(_ id: String) {
        guard workspace.opensInApp(id) else {
            withAnimation(.spring(duration: 0.38, bounce: 0.12)) { workspace.expand(id) }
            return
        }
        if workspace.expandedId != nil { collapse() }
        workspace.selectedId = id
        workspace.openNative(id, at: openedRect(from: tileFrames[id]).flatMap(screenRect(fromWindow:)))
    }

    /// Tessera's own transcript of a desktop-app conversation.
    func showTranscript(_ id: String) {
        withAnimation(.spring(duration: 0.38, bounce: 0.12)) { workspace.expand(id) }
    }

    /// Set by the board: its rectangle in the window.
    @ObservationIgnored var boardFrame: CGRect?

    /// Where a tile opened from `source` settles (window coordinates, top-left origin).
    func openedRect(from source: CGRect?) -> CGRect? {
        boardFrame.map { ExpandedPanel.target(from: source, board: $0) }
    }

    func collapse() {
        withAnimation(.spring(duration: 0.3, bounce: 0.05)) { workspace.collapse() }
        DispatchQueue.main.async { self.window?.makeFirstResponder(self.window?.contentView) }
    }

    func jumpToAttention() {
        if let id = workspace.nextAttention() { open(id) }
    }

    func cycle(_ delta: Int) {
        let tiles = workspace.visibleTiles
        guard !tiles.isEmpty else { return }
        let current = workspace.expandedId ?? workspace.selectedId
        let i = tiles.firstIndex { $0.id == current } ?? 0
        let next = tiles[(i + delta + tiles.count) % tiles.count].id
        if workspace.expandedId != nil { open(next) } else { workspace.selectedId = next }
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

struct BoardCommands: Commands {
    let model: AppModel

    private func show(_ filter: Workspace.Filter) {
        withAnimation(.spring(duration: 0.35)) { model.workspace.filter = filter }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Shell") { model.workspace.launch(command: nil, cwd: model.contextDirectory) }
                .keyboardShortcut("t")
            Button("New Claude Code") { model.workspace.launch(command: "claude", cwd: model.contextDirectory) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("New Codex") { model.workspace.launch(command: "codex", cwd: model.contextDirectory) }
                .keyboardShortcut("t", modifiers: [.command, .option])
            ForEach(model.workspace.installedApps, id: \.self) { app in
                Button(app == .claude ? "New Claude App Session" : "New Codex App Thread") { model.newAppConversation(app) }
            }
            Button("Open Web Tile…") { model.paletteMode = .url; model.showPalette = true }
                .keyboardShortcut("l")
            Divider()
            Button("Close Tile") {
                if let id = model.workspace.expandedId ?? model.workspace.selectedId { model.workspace.close(id) }
            }
            .keyboardShortcut("w")
        }
        CommandMenu("Board") {
            Button("Command Palette") { model.paletteMode = .all; model.showPalette.toggle() }
                .keyboardShortcut("k")
            Button("Open / Close Tile") {
                if model.workspace.expandedId != nil { model.collapse() } else if let id = model.workspace.selectedId { model.open(id) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            Button("Next Tile Needing Me") { model.jumpToAttention() }
                .keyboardShortcut("j")
            Button("Next Tile") { model.cycle(1) }
                .keyboardShortcut("]")
            Button("Previous Tile") { model.cycle(-1) }
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
            Button("Shut Down All Terminals") { model.workspace.shutDownAll() }
                .keyboardShortcut("w", modifiers: [.command, .option, .shift])
            Button("Resume All Terminals") { model.workspace.resumeAll() }
                .keyboardShortcut("r", modifiers: [.command, .option, .shift])
            Divider()
            Button("Show All") { show(.all) }.keyboardShortcut("1")
            Button("Show Needs You") { show(.attention) }.keyboardShortcut("2")
            ForEach(Array(model.workspace.groups.list.prefix(7).enumerated()), id: \.element.id) { i, group in
                Button("Show \(group.name)") { show(.group(group.id)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 3)")))
            }
        }
    }
}
