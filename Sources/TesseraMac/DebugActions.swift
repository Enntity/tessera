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
        // (Encoding a large window takes long enough to hold everything up; `shot=` alone does without.)
        if let path = ProcessInfo.processInfo.environment["TESSERA_SNAPSHOT"], !path.isEmpty {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.writeSnapshot(of: self?.window, to: path) }
            }
        }
    }

    /// Actions, separated by `;`:
    /// - set-up, straight into the workspace: `cwd=<dir>` (where the next tiles start), `launch=<cmd>`,
    ///   `url=<url>`, `tab=<name>` (a tab holding the first two tiles), `shutdown`, `rename=<title>` (the
    ///   selected tile), `machine=<ssh host>`, `remote`, `pairurl=<file>`, `privacy[=off]`, `lane[=off]`,
    ///   `size=<w>x<h>`, `wait=<s>`, `pace=<s>` (the gap between the actions that follow; 1 s unless set);
    /// - what a user does: `select=<title>`, `open[=terminal|web|<title>|<id>]` (never an app conversation),
    ///   `click=<title>` or `click=<x>,<y>` (a tile, or a point in the window) and `dblclick=…`,
    ///   `hover=<x>,<y>` or `hover=<title>` (the pointer moved there, or onto that tile's row in the lane),
    ///   `key=up,down,left,right,return,esc,delete`, `type=<text>`, `cmd=[shift+][option+]<key>` and
    ///   `ctrl=<key>` (a ⌘ or ⌃ shortcut, through the menu bar; `<key>` may be `return` or `tab`), `undo`
    ///   (Edit ▸ Undo, with the board's window in front), `run=<BoardCommand>`, `closefront=<window title>`,
    ///   `filter=all|<tab>`, `chip=<BoardQuery.Chip>` (a filter chip, toggled), `pane=<label>` (a pane of
    ///   the open Settings window), `dock=<title>` and `undock=<title>` (as the tile's menu does),
    ///   `expand=<title>` (a docked tile's full-size button), `drag=<x>,<y>,<x>,<y>` (from a point to a point);
    /// - `dump=<file>[?<query>]`: what is selected, open, on show, waiting and closed, each tile's state,
    ///   who has the keyboard, whether the window can be seen, and the palette's rows for `<query>`, as JSON;
    /// - `shot=<file>[?<window title>]`: a capture of the board's window (or the window so titled) as it
    ///   is at that moment.
    private func runDebugActions(_ actions: [String], after delay: Double = 2, pace: Double = 1) {
        guard let first = actions.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            let parts = first.split(separator: "=", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            var pace = pace
            var next = pace
            switch parts[0] {
            case "cwd": workspace.defaultDirectory = arg
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
            case "privacy": privacyMode = arg != "off"
            case "lane": showLane = arg != "off"
            case "size":
                let side = arg.split(separator: "x").compactMap { Double($0) }
                if side.count == 2, let window { window.setContentSize(CGSize(width: side[0], height: side[1])) }
            case "closefront": closeFront(key: NSApp.windows.first { $0.title == arg }) // ⌘W as if that window were key
            case "pane":
                // A pane of the Settings window, by the label in its toolbar.
                let item = NSApp.windows.compactMap(\.toolbar).flatMap(\.items).first { $0.label == arg }
                if let item, let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
            case "wait": next = Double(arg) ?? 1
            case "pace":
                pace = Double(arg) ?? 1
                next = pace
            case "select": if let id = debugTile(arg) { workspace.select(id) }
            case "open":
                // Opening an app conversation would drive the real Claude or Codex app.
                if let id = arg.isEmpty ? workspace.selectedId : debugTile(arg) ?? arg, !workspace.opensInApp(id) { open(id) }
            case "click", "dblclick":
                guard let point = debugPoint(arg) else { break }
                debugClick(at: point, count: 1)
                if parts[0] == "dblclick" {
                    // The second click of a real double-click arrives once the panel has begun to open.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.debugClick(at: point, count: 2) }
                }
            case "hover":
                // A row of the lane by its tile's title (it changes size under the pointer, and would
                // then look for the real one), or a point.
                debugHover = arg.contains(",") ? nil : debugTile(arg)
                guard debugHover == nil, let point = debugPoint(arg), let window, let content = window.contentView else { break }
                let at = CGPoint(x: point.x, y: content.bounds.height - point.y)
                if let event = NSEvent.mouseEvent(with: .mouseMoved, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                    // No tracking area fires for an event the window server didn't send: the views
                    // under the point are told themselves.
                    var view = content.hitTest(content.convert(at, from: nil))
                    while let v = view {
                        v.mouseMoved(with: event)
                        view = v.superview
                    }
                }
            case "key":
                let keys: [String: (UInt16, String)] = ["up": (126, "\u{F700}"), "down": (125, "\u{F701}"), "left": (123, "\u{F702}"),
                                                        "right": (124, "\u{F703}"), "return": (36, "\r"), "esc": (53, "\u{1B}"),
                                                        "delete": (51, "\u{7F}")]
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
                onBoard { $0.filter = $0.groups.list.first { $0.name == arg }.map { .group($0.id) } ?? .all }
            case "chip": BoardQuery.Chip(rawValue: arg).map(toggle)
            case "dock", "undock": if let id = debugTile(arg) { setDocked(id, parts[0] == "dock") }
            case "expand": debugTile(arg).map(expand)
            case "drag":
                let xy = arg.split(separator: ",").compactMap { Double($0) }
                guard xy.count == 4 else { break }
                let (from, to) = (CGPoint(x: xy[0], y: xy[1]), CGPoint(x: xy[2], y: xy[3]))
                debugMouse(.leftMouseDown, at: from)
                for step in 1...4 {
                    let t = Double(step) / 4
                    debugMouse(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
                }
                debugMouse(.leftMouseUp, at: to)
            case "dump": debugDump(to: arg)
            case "shot":
                let target = arg.split(separator: "?", maxSplits: 1).map(String.init)
                writeSnapshot(of: target.count > 1 ? NSApp.windows.first { $0.title == target[1] } : window, to: target[0])
            default: break
            }
            runDebugActions(Array(actions.dropFirst()), after: next, pace: pace)
        }
    }

    /// The first tile on show of that kind (`terminal`, `web`, `conversation`: a Claude or Codex one,
    /// not yet docked) or with that text in its title.
    private func debugTile(_ name: String) -> String? {
        let kinds: [String: TileKind] = ["terminal": .terminal, "web": .browser, "conversation": .agentSession]
        return workspace.visibleIds.first { id in
            guard let tile = workspace.info(id) else { return false }
            // (A docked dsh session would start its server.)
            if tile.kind == .agentSession, kinds[name] == tile.kind { return tile.flavor != .dsh && !workspace.dock.contains(id) }
            return kinds[name] == tile.kind || tile.title.localizedCaseInsensitiveContains(name)
        }
    }

    /// The centre of the tile `name` finds, or the point `x,y` itself (window coordinates, top-left origin).
    private func debugPoint(_ name: String) -> CGPoint? {
        let xy = name.split(separator: ",").compactMap { Double($0) }
        if xy.count == 2 { return CGPoint(x: xy[0], y: xy[1]) }
        return debugTile(name).flatMap(tileFrame).map { CGPoint(x: $0.midX, y: $0.midY) }
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

    /// `point` is in window coordinates, top-left origin (as `tileFrame`). The test copy is never the
    /// active app, where a first click would only bring its window forward: here every click lands.
    private func debugClick(at point: CGPoint, count: Int) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] { debugMouse(type, at: point, count: count) }
    }

    private func debugMouse(_ type: NSEvent.EventType, at point: CGPoint, count: Int = 1) {
        guard let window, let content = window.contentView else { return }
        let accept: @convention(block) (AnyObject, NSEvent?) -> Bool = { _, _ in true }
        class_replaceMethod(Swift.type(of: content), #selector(NSView.acceptsFirstMouse(for:)), imp_implementationWithBlock(accept), "c@:@")
        let at = CGPoint(x: point.x, y: content.bounds.height - point.y)
        // A click in a terminal or page gives it the keyboard; a window in the background doesn't do that itself.
        if type == .leftMouseDown, let hit = content.hitTest((content.superview ?? content).convert(at, from: nil)), hit !== content, hit.acceptsFirstResponder {
            window.makeFirstResponder(hit)
        }
        if let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1) {
            window.sendEvent(event)
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
            "query": workspace.query.text, "chips": Dictionary(uniqueKeysWithValues: BoardQuery.Chip.allCases.map {
                ($0.rawValue + (workspace.query.chips.contains($0) ? " on" : ""), workspace.count($0))
            }),
            "dock": workspace.docked.map(title), "dockWidth": workspace.dockWidth ?? 0, "keyboardDock": title(keyboardDock),
            "density": density.minTileWidth, "columns": grid(count: workspace.visibleIds.count, in: boardFrame?.size ?? .zero).columns,
            "hosted": workspace.order.compactMap { id -> String? in
                guard let view: NSView = workspace.terminals[id]?.view ?? workspace.browsers[id]?.webView, let host = view.superview else { return nil }
                let cells = workspace.info(id).flatMap { tile in tile.cols.map { " \($0) columns" } } ?? ""
                return "\(title(id)): \(Int(view.frame.minX)),\(Int(view.frame.minY)) \(Int(view.frame.width))x\(Int(view.frame.height)) in \(Int(host.frame.width))x\(Int(host.frame.height))\(cells)"
            },
            "lane": showLane, "places": workspace.allTiles.map { "\($0.title): \($0.subtitle)" },
            "palette": showPalette ? "\(paletteMode)" : "",
            "firstResponder": window?.firstResponder.map { String(describing: type(of: $0)) } ?? "",
            "keyWindow": key === window ? "board" : key?.title ?? "",
            // Hidden (behind other windows, the screen locked), continuous effects stop and nothing is drawn.
            "onScreen": window?.occlusionState.contains(.visible) == true,
            "windows": NSApp.windows.filter(\.isVisible).map(\.title),
            "scroll": boardScroll,
            "suspended": workspace.order.filter(workspace.isSuspended).map(title),
            "activity": workspace.allTiles.map { "\($0.title): \($0.activity.rawValue)\($0.attention ? " unseen" : "")" },
            "queue": board.queue.map(title),
            "counts": ["needsInput": board.needsInput.count, "failed": board.failed.count, "done": board.done.count, "working": board.working.count],
            "closed": workspace.recentlyClosed.tiles.map(\.title), "hidden": workspace.hiddenTiles.map(\.title),
            "toast": closedToast?.text ?? "", "undo": undo?.canUndo == true ? undo?.undoMenuItemTitle ?? "" : "", "undoMenu": undoTitle,
            "rows": paletteItems(parts.count > 1 ? parts[1] : "").map { "\($0.title) — \($0.subtitle)" },
            "menus": (NSApp.mainMenu?.items ?? []).flatMap { menu in
                (menu.submenu?.items ?? []).filter { !$0.keyEquivalent.isEmpty }.map { "\(menu.title) ▸ \($0.title) [\($0.keyEquivalent)]\($0.isEnabled ? "" : " off")" }
            },
            "wouldOpenInApp": WindowPlacer.dryRun ?? []
        ]
        try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
    }

    /// Captures a window to a PNG so layout can be checked without screen capture rights.
    /// Apps may always capture their own windows; the symbol is looked up dynamically because the SDK hides it.
    private func writeSnapshot(of window: NSWindow?, to path: String) {
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
