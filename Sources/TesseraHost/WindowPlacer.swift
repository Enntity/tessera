import AppKit
import ApplicationServices

/// Opens another app's content and places its window on a rectangle of the screen, so opening a
/// tile lands the real app where the opened tile would sit.
public enum WindowPlacer {
    #if DEBUG
    /// A scripted development run (TESSERA_DEBUG_ACTIONS) must never drive the Claude or Codex app
    /// someone is using: it only records what it would have opened.
    @MainActor public private(set) static var dryRun: [String]? = ProcessInfo.processInfo.environment["TESSERA_DEBUG_ACTIONS"].map { _ in [] }
    #endif

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security → Accessibility.
    public static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// `rect` is in AppKit screen coordinates (origin bottom-left of the primary display).
    @MainActor
    public static func open(_ url: URL?, bundleID: String, placeAt rect: CGRect?) {
        #if DEBUG
        if dryRun != nil {
            dryRun?.append(url?.absoluteString ?? bundleID)
            return
        }
        #endif
        if let url {
            NSWorkspace.shared.open(url)
        } else if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
        guard let rect, isTrusted else { return }
        let target = axRect(fromAppKit: rect)
        // The app needs a moment to come forward and switch threads; retry briefly.
        for delay in [0.15, 0.35, 0.7, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { place(bundleID: bundleID, frame: target) }
        }
    }

    /// Accessibility uses a top-left origin on the primary display.
    static func axRect(fromAppKit r: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? r.maxY
        return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    @discardableResult
    static func place(bundleID: String, frame: CGRect) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) != .success {
            var windows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windows) == .success,
                  let first = (windows as? [AXUIElement])?.first else { return false }
            windowRef = first
        }
        guard let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return false }
        let window = windowRef as! AXUIElement
        var origin = frame.origin
        var size = frame.size
        if let position = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        return true
    }
}
