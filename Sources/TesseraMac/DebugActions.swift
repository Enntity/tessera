#if DEBUG
import AppKit
import TesseraHost
import TesseraKit

/// Development aid: a scripted run of the app (see `scripts/debug-run.sh`), so behaviour can be
/// checked without anyone at the keyboard. Only read from the environment, only in debug builds.
extension AppModel {
    func startDebugRun() {
        if let actions = ProcessInfo.processInfo.environment["TESSERA_DEBUG_ACTIONS"] {
            runDebugActions(actions.split(separator: ";").map(String.init))
        }
        if let path = ProcessInfo.processInfo.environment["TESSERA_SNAPSHOT"] {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.writeSnapshot(to: path) }
            }
        }
    }

    /// Actions, separated by `;`:
    /// - set-up, straight into the workspace: `launch=<cmd>`, `url=<url>`, `tab=<name>` (a tab holding
    ///   the first two tiles), `shutdown`, `rename=<title>` (the selected tile), `machine=<ssh host>`,
    ///   `remote`, `pairurl=<file>`, `privacy`, `size=<w>x<h>`, `wait=<s>`;
    /// - what a user does: `select=<title>`, `open[=terminal|web|<title>|<id>]` (never an app conversation),
    ///   `click=<title>`, `dblclick=<title>`, `key=up,down,left,right,return,esc`, `type=<text>`,
    ///   `cmd=[shift+][option+]<key>` and `ctrl=<key>` (a ⌘ or ⌃ shortcut, through the menu bar; `<key>` may
    ///   be `return` or `tab`), `undo` (Edit ▸ Undo, as whoever has the keyboard gets it), `run=<BoardCommand>`,
    ///   `closefront=<window title>`, `filter=all|attention|<tab>`;
    /// - `dump=<file>[?<query>]`: what is selected, open, on show, waiting and closed, who has the
    ///   keyboard, and the palette's rows for `<query>`, as JSON.
    private func runDebugActions(_ actions: [String], after delay: Double = 2) {
        guard let first = actions.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            let parts = first.split(separator: "=", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            var next = 1.0
            switch parts[0] {
            case "launch": workspace.launch(command: arg.isEmpty ? nil : arg)
            case "url": workspace.openBrowser(arg)
            case "tab":
                let id = workspace.createGroup(named: arg)
                for tile in workspace.allTiles.prefix(2) { workspace.move(tile: tile.id, toGroup: id) }
            case "shutdown": if let id = workspace.selectedId { workspace.shutDown(id) }
            case "rename": if let id = workspace.selectedId { workspace.rename(id, to: arg) }
            case "machine": workspace.machines.add(host: arg, name: nil)
            case "remote": server.start() // not persisted: normal launches keep the user's setting
            case "pairurl": try? server.pairingURL?.absoluteString.write(toFile: arg, atomically: true, encoding: .utf8)
            case "privacy": privacyMode = true
            case "size":
                let side = arg.split(separator: "x").compactMap { Double($0) }
                if side.count == 2, let window { window.setContentSize(CGSize(width: side[0], height: side[1])) }
            case "closefront": closeFront(key: NSApp.windows.first { $0.title == arg }) // ⌘W as if that window were key
            case "wait": next = Double(arg) ?? 1
            case "select": if let id = debugTile(arg) { workspace.select(id) }
            case "open":
                // Opening an app conversation would drive the real Claude or Codex app.
                if let id = arg.isEmpty ? workspace.selectedId : debugTile(arg) ?? arg, !workspace.opensInApp(id) { open(id) }
            case "click", "dblclick":
                guard let id = debugTile(arg), let frame = tileFrame(id) else { break }
                debugClick(at: CGPoint(x: frame.midX, y: frame.midY), count: 1)
                if parts[0] == "dblclick" {
                    // The second click of a real double-click arrives once the panel has begun to open.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.debugClick(at: CGPoint(x: frame.midX, y: frame.midY), count: 2) }
                }
            case "key":
                let keys: [String: (UInt16, String)] = ["up": (126, "\u{F700}"), "down": (125, "\u{F701}"), "left": (123, "\u{F702}"),
                                                        "right": (124, "\u{F703}"), "return": (36, "\r"), "esc": (53, "\u{1B}")]
                for name in arg.split(separator: ",") {
                    if let (code, chars) = keys[String(name)] { debugKey(chars, code: code, flags: code > 122 ? [.function, .numericPad] : []) }
                }
            case "type": for c in arg { debugKey(String(c)) }
            case "cmd", "ctrl":
                var names = arg.split(separator: "+").map(String.init)
                let key = names.popLast() ?? ""
                var flags: NSEvent.ModifierFlags = parts[0] == "ctrl" ? .control : .command
                if names.contains("shift") { flags.insert(.shift) }
                if names.contains("option") { flags.insert(.option) }
                if let event = debugKeyEvent(.keyDown, ["return": "\r", "tab": "\t"][key] ?? key, code: 0, flags: flags) {
                    NSApp.mainMenu?.performKeyEquivalent(with: event)
                }
            case "undo": undo(key: window) // Edit ▸ Undo as if the board's window were key
            case "run": BoardCommand(rawValue: arg).map(run)
            case "filter":
                onBoard { $0.filter = arg == "attention" ? .attention : $0.groups.list.first { $0.name == arg }.map { .group($0.id) } ?? .all }
            case "dump": debugDump(to: arg)
            default: break
            }
            runDebugActions(Array(actions.dropFirst()), after: next)
        }
    }

    /// The first tile on show of that kind (`terminal`, `web`) or with that text in its title.
    private func debugTile(_ name: String) -> String? {
        let kinds: [String: TileKind] = ["terminal": .terminal, "web": .browser]
        return workspace.visibleIds.first { id in
            workspace.info(id).map { kinds[name] == $0.kind || $0.title.localizedCaseInsensitiveContains(name) } ?? false
        }
    }

    private func debugKeyEvent(_ type: NSEvent.EventType, _ chars: String, code: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window?.windowNumber ?? 0, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
    }

    /// Straight to the window: works while the test copy is in the background.
    private func debugKey(_ chars: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = debugKeyEvent(type, chars, code: code, flags: flags) { window?.sendEvent(event) }
        }
    }

    /// `point` is in window coordinates, top-left origin (as `tileFrame`).
    private func debugClick(at point: CGPoint, count: Int) {
        guard let window, let content = window.contentView else { return }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x, y: content.bounds.height - point.y), modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: count, pressure: 1) {
                window.sendEvent(event)
            }
        }
    }

    private func debugDump(to target: String) {
        func title(_ id: String?) -> String { id.flatMap(workspace.info)?.title ?? "" }
        let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
        let path = parts[0]
        let key = NSApp.keyWindow
        let board = workspace.state
        let undo = window?.undoManager
        let state: [String: Any] = [
            "selected": title(workspace.selectedId), "open": title(workspace.expandedId),
            "panelOnScreen": workspace.expandedId.flatMap { workspace.terminals[$0]?.view.window ?? workspace.browsers[$0]?.webView.window } != nil,
            "selectedId": workspace.selectedId ?? "", "openId": workspace.expandedId ?? "",
            "openURL": workspace.expandedId.flatMap(workspace.info)?.url ?? "",
            "visible": workspace.visibleIds.map(title), "tiles": workspace.order.count,
            "filter": "\(workspace.filter)", "tabs": workspace.groups.list.map { [$0.name: $0.tileIds.map(title)] },
            "palette": showPalette ? "\(paletteMode)" : "",
            "firstResponder": window?.firstResponder.map { String(describing: type(of: $0)) } ?? "",
            "keyWindow": key === window ? "board" : key?.title ?? "",
            "windows": NSApp.windows.filter(\.isVisible).map(\.title),
            "scroll": boardScroll,
            "suspended": workspace.order.filter(workspace.isSuspended).map(title),
            "queue": board.queue.map(title),
            "counts": ["needsInput": board.needsInput.count, "failed": board.failed.count, "done": board.done.count, "working": board.working.count],
            "closed": workspace.recentlyClosed.tiles.map(\.title), "hidden": workspace.hiddenTiles.map(\.title),
            "toast": closedToast?.text ?? "", "undo": undo?.canUndo == true ? undo?.undoMenuItemTitle ?? "" : "",
            "rows": paletteItems(parts.count > 1 ? parts[1] : "").map { "\($0.title) — \($0.subtitle)" },
            "wouldOpenInApp": WindowPlacer.dryRun ?? []
        ]
        try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
    }

    /// Captures the board window to a PNG so layout can be checked without screen capture rights.
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
}
#endif
