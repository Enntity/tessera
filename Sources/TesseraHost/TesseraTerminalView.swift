import AppKit
import Foundation
import SwiftTerm
import TesseraKit

/// Where a paste should read from, and where it should write to. Injected so tests can act on a
/// named pasteboard of their own and capture exactly the bytes the terminal would have sent,
/// without ever touching the user's real clipboard.
@MainActor
public protocol TerminalPasteContext: AnyObject {
    /// The pasteboard clipboard payloads are read from. Production uses the general one.
    var pasteboard: NSPasteboard { get }
    /// What the terminal would send to the program (paths, quoted text, control sequences).
    func pasteSend(_ bytes: [UInt8])
    /// The program's current bracketed-paste mode, read straight from the terminal.
    func pasteBracketedPasteMode() -> Bool
    /// A short sound to make a failure visible instead of a silent drop.
    func pasteBeep()
    /// A file URL to write an image to for the plain-shell fallback. Nil when none can be reached
    /// (for example, a tile on another machine has no path the remote program could use).
    func pasteImageFallbackURL() -> URL?
    /// The flavor under the keyboard. Only a plain `.shell` takes the file fallback; every other
    /// command is a harness that may understand a native clipboard paste, so it is routed generically.
    func pasteFlavor() -> AgentFlavor
    /// A paste produced something the user should know about. Never written to the PTY.
    func pasteNotice(_ message: String)
}

/// A context that can hand a native clipboard paste to the terminal's own key encoder. Production
/// (`TesseraTerminalView` + `TerminalSession`) implements this; a plain recorder simply does not.
@MainActor
public protocol TerminalNativePaste: AnyObject {
    /// Synthetic Ctrl+V through SwiftTerm's `keyDown`, honoring negotiated keyboard flags.
    @discardableResult
    func sendNativePaste() -> Bool
}

/// A terminal view that understands every way macOS hands the user's clipboard to a terminal:
/// ⌘V / Edit▸Paste, file-URL and text drags, and images (screenshots, browser, Preview).
///
/// SwiftTerm's own `paste(_:)` reads only `.string`; file URLs (Finder's preview plus the real
/// paths) and images otherwise come through bare. This subclass reads the richer types, keeps
/// SwiftTerm's keyboard handling untouched, and hands control to a context so the routing can be
/// exercised on a named pasteboard.
open class TesseraTerminalView: TerminalView {
    /// Nil in the rare case a view is used without a session; paste then falls back to SwiftTerm's.
    public weak var pasteContext: TerminalPasteContext?
    private var consumedPasteKeyCode: UInt16?
    private var pasteReleaseMonitor: Any?
    private var pasteReleaseGeneration = 0

    deinit {
        if let monitor = pasteReleaseMonitor { NSEvent.removeMonitor(monitor) }
    }

    public override init(frame: CGRect, font: NSFont?) {
        // SwiftTerm's default DA1 reply advertises sixel (";4"), which makes harnesses like omp
        // send inline SIXEL images. SwiftTerm attaches those to buffer lines, and ordinary
        // row-by-row repaints (how these agents redraw a viewport while streaming) do not clear
        // them, so every repaint stacks a new ghost of the image; the thumbnail renderer cannot
        // draw them at all. Decline the advertisement: clients then fall back to text charts,
        // which render correctly in tiles and thumbnails alike.
        super.init(frame: frame, font: font, options: TerminalOptions(enableSixelReported: false))
        registerForDraggedTypes([.fileURL, .URL, .string, .tiff, .png, .rtf])
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .URL, .string, .tiff, .png, .rtf])
    }

    // MARK: - Paste

    /// ⌘V, Edit▸Paste, and the standard paste selector all land here. Toolbar/menu ⌘V may arrive here
    /// or through `performKeyEquivalent`; both read the same general clipboard.
    @objc
    open override func paste(_ sender: Any?) {
        if let event = NSApp.currentEvent, event.type == .keyDown, isStandardPasteShortcut(event) {
            consumePasteShortcut(event)
        }
        performPaste()
    }

    /// ⌘V reaches a view through `performKeyEquivalent` before `keyDown`. Only the standard Command-V
    /// is intercepted: Control/Alt/Option-Shift go straight to SwiftTerm's `keyDown`, which is what
    /// encoders (including the Kitty protocol) and agent shortcuts rely on.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isStandardPasteShortcut(event) {
            consumePasteShortcut(event)
            performPaste()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func consumePasteShortcut(_ event: NSEvent) {
        consumedPasteKeyCode = event.keyCode
        pasteReleaseGeneration += 1
        let generation = pasteReleaseGeneration
        if let monitor = pasteReleaseMonitor { NSEvent.removeMonitor(monitor) }
        // SwiftTerm's keyUp is not open to subclasses. Consume only this app's release of the
        // shortcut we handled, so Kitty clients don't receive an unmatched Command-V release.
        pasteReleaseMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] up in
            guard let self else { return up }
            return self.filterPasteRelease(up)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.pasteReleaseGeneration == generation else { return }
            self.clearPasteRelease()
        }
    }

    func filterPasteRelease(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, window?.firstResponder === self else { return event }
        return consumePasteRelease(event) ? nil : event
    }

    func consumePasteRelease(_ event: NSEvent) -> Bool {
        guard consumedPasteKeyCode == event.keyCode else { return false }
        clearPasteRelease()
        return true
    }

    private func clearPasteRelease() {
        consumedPasteKeyCode = nil
        if let monitor = pasteReleaseMonitor { NSEvent.removeMonitor(monitor) }
        pasteReleaseMonitor = nil
    }

    /// True only for Command-V with no other shortcut modifier. Caps Lock and function flags are
    /// ignored, because the system may set them on an otherwise plain ⌘V.
    func isStandardPasteShortcut(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(shortcutModifierMask)
        return mods == .command && event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    /// The modifiers that make a shortcut a shortcut. Caps Lock, Function/NumPad and device flags are
    /// deliberately excluded so ⌘V still works with Caps Lock on or from a function-key row.
    var shortcutModifierMask: NSEvent.ModifierFlags {
        [.control, .option, .command, .shift]
    }

    /// The one entry point for clipboard paste: ⌘V, Edit▸Paste, or a programmatic request.
    public func performPaste() {
        guard let context = pasteContext else {
            // No session bound (shouldn't happen in a tile): do exactly what SwiftTerm would.
            super.paste(self)
            return
        }
        TerminalPaste.performPaste(on: self, context: context)
    }

    /// Synthesize the exact Control-V keystroke and hand it to SwiftTerm's own `keyDown`, so the
    /// bytes an agent harness sees are identical to a user pressing Ctrl+V — including any Kitty
    /// keyboard flags the program negotiated (CSI-u encoding, release events, and so on).
    @discardableResult
    public func sendNativeControlV() -> Bool {
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(with: type,
                                           location: .zero,
                                           modifierFlags: .control,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window?.windowNumber ?? 0,
                                           context: nil,
                                           characters: "\u{16}",
                                           charactersIgnoringModifiers: "v",
                                           isARepeat: false,
                                           keyCode: 9)
        }
        guard let down = event(.keyDown), let up = event(.keyUp) else { return false }
        super.keyDown(with: down)
        super.keyUp(with: up)
        return true
    }

    // MARK: - Drop

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        TerminalPaste.draggingOperation(for: sender.draggingPasteboard) ?? super.draggingEntered(sender)
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        TerminalPaste.draggingOperation(for: sender.draggingPasteboard) ?? super.draggingUpdated(sender)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let context = pasteContext else { return super.performDragOperation(sender) }
        return TerminalPaste.performDrop(on: sender, context: context)
    }
}

/// Reading, quoting and routing one clipboard or drop payload. Kept free of view state so it is a
/// test seam: the view supplies a `TerminalPasteContext`, and the routed bytes are captured instead
/// of sent.
public enum TerminalPaste {

    /// What a payload holds, in preference order: real file URLs first, then a real image, and only
    /// then the `.string` / `.URL` / RTF-plain-text representations the same copy may also carry.
    /// A browser image copy puts both an image and a `.URL` on the pasteboard; the image must win so
    /// the harness receives the picture, not a link to it.
    public enum Payload: Equatable {
        case files([URL])
        case text(String)
        case image
        case unsupported
    }

    // MARK: Paste entry

    @MainActor
    public static func performPaste(on view: TerminalView, context: TerminalPasteContext) {
        switch classify(context.pasteboard) {
        case .files(let urls):
            sendPaths(urls, context: context)
        case .text(let text):
            sendText(text, context: context)
        case .image:
            routeImage(context, source: context.pasteboard)
        case .unsupported:
            if context.pasteboard.types?.isEmpty == false, context.pasteFlavor() != .shell {
                routeNativeForNonText(context)
            } else {
                beepOrNotify(context, "Nothing to paste")
            }
        }
    }

    /// Classify a pasteboard once. Finder file URLs win over any preview, image wins over the
    /// companion `.string` / `.URL` a browser copy carries, and only then come text and URL.
    public static func classify(_ pasteboard: NSPasteboard) -> Payload {
        let files = fileURLs(from: pasteboard)
        if !files.isEmpty { return .files(files) }
        if hasImage(pasteboard) { return .image }
        if let string = pasteboard.string(forType: .string) { return .text(string) }
        if let url = urlString(from: pasteboard), !url.isEmpty { return .text(url) }
        if let rtf = plainTextFromRTF(pasteboard), !rtf.isEmpty { return .text(rtf) }
        return .unsupported
    }

    // MARK: Text

    /// Bracketed-paste framing is applied explicitly (never left to a path that might not mark the
    /// insert as a paste), so multiline text and a literal UTF-8 payload survive even when the
    /// program has negotiated Kitty keyboard modes.
    @MainActor
    static func sendText(_ text: String, context: TerminalPasteContext) {
        pasteText(text, bracketed: context.pasteBracketedPasteMode(), context: context)
    }

    @MainActor
    static func pasteText(_ text: String, bracketed: Bool, context: TerminalPasteContext) {
        var bytes: [UInt8] = []
        if bracketed { bytes.append(contentsOf: EscapeSequences.bracketedPasteStart) }
        bytes.append(contentsOf: Array(text.utf8))
        if bracketed { bytes.append(contentsOf: EscapeSequences.bracketedPasteEnd) }
        context.pasteSend(bytes)
    }

    // MARK: Files

    /// Insert every filesystem path, safely quoted, with no trailing newline and no submit. The
    /// quoted text uses bracketed-paste framing when the program asked for it, so a path is never
    /// typed into a raw line editor as executable input when bracket mode is on.
    @MainActor
    @discardableResult
    public static func sendPaths(_ urls: [URL], context: TerminalPasteContext) -> Bool {
        let paths = urls.filter(\.isFileURL).map(\.path)
        guard !paths.isEmpty else {
            beepOrNotify(context, "That clipboard has no file paths")
            return false
        }
        for path in paths where containsUnsafeControlBytes(path) {
            beepOrNotify(context, "That file name has control characters and can't be pasted")
            return false
        }
        let line = paths.map(quote).joined(separator: " ")
        pasteText(line, bracketed: context.pasteBracketedPasteMode(), context: context)
        return true
    }

    /// Whether a path carries a C0/C1 control byte that would become terminal input (CR, LF, TAB,
    /// ESC, DEL…). Such a path is rejected outright rather than typed as an executable line.
    static func containsUnsafeControlBytes(_ path: String) -> Bool {
        path.unicodeScalars.contains { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) }
    }

    /// Quote a path for any common shell: single quotes, with an embedded quote closed and reopened.
    /// `'/a'\''b'` is the recipe bash, zsh, sh, ksh and fish all accept.
    public static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Every file URL a pasteboard carries, in the order given, deduplicated. `.fileURL` is read as
    /// an array and as a single string, and `.URL` filtered to file urls, to catch every producer.
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        if let list = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            urls.append(contentsOf: list)
        }
        if let raw = pasteboard.string(forType: .fileURL), let url = URL(string: raw), url.isFileURL {
            urls.append(url)
        }
        if let strings = pasteboard.propertyList(forType: .fileURL) as? [String] {
            urls.append(contentsOf: strings.compactMap { URL(string: $0) }.filter(\.isFileURL))
        }
        var seen = Set<String>()
        return urls.filter { $0.isFileURL && seen.insert($0.path).inserted }
    }

    /// A URL represented as text: the `.URL` type when present, else an `http(s)://` plain string
    /// that SwiftTerm would have pasted as text anyway.
    static func urlString(from pasteboard: NSPasteboard) -> String? {
        if let url = pasteboard.string(forType: .URL), !url.isEmpty { return url }
        if let string = pasteboard.string(forType: .string),
           let parsed = URL(string: string), parsed.scheme != nil, !parsed.isFileURL {
            return string
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let webURLs = urls.filter { !$0.isFileURL }
            if !webURLs.isEmpty { return webURLs.map(\.absoluteString).joined(separator: " ") }
        }
        return nil
    }

    /// The plain-text projection of an RTF payload, which SwiftTerm's `.string` read would miss.
    static func plainTextFromRTF(_ pasteboard: NSPasteboard) -> String? {
        guard let data = pasteboard.data(forType: .rtf),
              let attributed = NSAttributedString(rtf: data, documentAttributes: nil) else { return nil }
        return attributed.string
    }

    /// Whether anything dropped here can be sent to the program.
    @MainActor
    public static func draggingOperation(for pasteboard: NSPasteboard) -> NSDragOperation? {
        switch classify(pasteboard) {
        case .unsupported: return nil
        default: return .copy
        }
    }

    /// A drop reads only the drag's own pasteboard, never the general clipboard or a Ctrl+V: a
    /// harness seeing Ctrl+V would read the wrong image. Text and file URLs go in as framed, quoted
    /// text; a real image is materialized to a unique local PNG and its quoted path is pasted.
    @MainActor
    public static func performDrop(on sender: NSDraggingInfo, context: TerminalPasteContext) -> Bool {
        performDrop(from: sender.draggingPasteboard, context: context)
    }

    @MainActor
    @discardableResult
    public static func performDrop(from pasteboard: NSPasteboard, context: TerminalPasteContext) -> Bool {
        switch classify(pasteboard) {
        case .files(let urls):
            return sendPaths(urls, context: context)
        case .text(let text):
            sendText(text, context: context)
            return true
        case .image:
            return materializeImage(context, source: pasteboard)
        case .unsupported:
            beepOrNotify(context, "That drop can't be typed here")
            return false
        }
    }

    // MARK: Images

    /// Whether the pasteboard holds an image we can decode (screenshot, browser, Preview). Read
    /// directly, once, from the pasteboard's own representations.
    public static func hasImage(_ pasteboard: NSPasteboard) -> Bool {
        if let type = pasteboard.availableType(from: [.png, .tiff]), pasteboard.data(forType: type) != nil {
            return true
        }
        return (pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.isEmpty == false
    }

    /// The decoded image. Only consulted after `classify` has already decided this is `.image`.
    static func imageRepresentations(_ pasteboard: NSPasteboard) -> [NSImage] {
        var images: [NSImage] = []
        if let list = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            images.append(contentsOf: list)
        }
        for type in [NSPasteboard.PasteboardType.tiff, .png] {
            if let data = pasteboard.data(forType: type), let image = NSImage(data: data) {
                images.append(image)
            }
        }
        return images
    }

    /// An image cannot be typed. Every command that is not a plain shell is treated as a harness that
    /// may understand a native clipboard paste, so it is handed off to Ctrl+V through the view's own
    /// keyDown encoding; no per-tool allowlist. A plain shell has no native image input, so it saves
    /// a private local PNG and pastes its quoted path. Anything unknown beeps rather than emitting
    /// raw binary.
    @MainActor
    @discardableResult
    static func routeImage(_ context: TerminalPasteContext, source: NSPasteboard) -> Bool {
        if context.pasteFlavor() != .shell, let native = context as? TerminalNativePaste,
           native.sendNativePaste() {
            return true
        }
        return materializeImage(context, source: source)
    }

    @MainActor
    private static func materializeImage(_ context: TerminalPasteContext, source: NSPasteboard) -> Bool {
        if let url = context.pasteImageFallbackURL(), savePNG(from: source, to: url) {
            return sendPaths([url], context: context)
        }
        beepOrNotify(context, "This clipboard image can't be pasted here")
        return false
    }

    /// Copy any non-text clipboard payload to a harness through the same native Ctrl+V keyDown path,
    /// so arbitrary formats a harness supports reach it. Never emits raw binary to the PTY.
    @MainActor
    @discardableResult
    static func routeNativeForNonText(_ context: TerminalPasteContext) -> Bool {
        guard context.pasteFlavor() != .shell, let native = context as? TerminalNativePaste else {
            beepOrNotify(context, "This clipboard data can't be pasted here")
            return false
        }
        guard native.sendNativePaste() else {
            beepOrNotify(context, "This clipboard data can't be pasted here")
            return false
        }
        return true
    }

    /// Preserve an already-valid PNG exactly; otherwise transcode the decoded image to PNG.
    /// The directory is created 0700 and the file written 0600; an existing path is never replaced.
    @discardableResult
    public static func savePNG(from pasteboard: NSPasteboard, to url: URL) -> Bool {
        guard let bytes = pngBytes(from: pasteboard) else { return false }
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            // Never replace an existing file: a different UUID keeps every save its own path.
            guard !FileManager.default.fileExists(atPath: url.path) else { return false }
            try bytes.write(to: url, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    /// The PNG bytes for the pasteboard's image, raw when the payload already is a valid PNG.
    static func pngBytes(from pasteboard: NSPasteboard) -> Data? {
        if let data = pasteboard.data(forType: .png), NSImage(data: data) != nil,
           data.starts(with: [0x89, 0x50, 0x4e, 0x47]) {
            return data
        }
        guard let image = imageRepresentations(pasteboard).first,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png
    }

    /// Where the plain-shell fallback is expected to write. A unique private cache directory, so a
    /// saved image is never overwritten by (or overwrites) another.
    public static func imageFallbackDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Tessera/PastedImages", isDirectory: true)
    }

    public static func imageFallbackURL(now: Date = Date()) -> URL {
        let stamp = Int(now.timeIntervalSince1970 * 1000)
        let name = "paste-\(stamp)-\(UUID().uuidString.prefix(8)).png"
        return imageFallbackDirectory().appendingPathComponent(name)
    }

    // MARK: Failure

    /// A failed paste is audible and recorded, never typed into the program.
    @MainActor
    static func beepOrNotify(_ context: TerminalPasteContext, _ message: String) {
        context.pasteBeep()
        context.pasteNotice(message)
    }
}
