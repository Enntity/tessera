import AppKit
import Observation
import TesseraKit
import WebKit

/// A web page as a tile. The WKWebView stays alive (logged-in state, media, scroll): the tile shows it
/// live and scaled down, the expanded panel re-parents it, and a snapshot stands in on the tile while
/// the panel has it.
@Observable
@MainActor
public final class BrowserSession: NSObject {
    public let id: String
    public private(set) var info: TileInfo
    public private(set) var snapshot: NSImage?
    /// The snapshot as a coarse, unreadable mosaic, for privacy mode.
    public private(set) var mosaic: NSImage?
    @ObservationIgnored public let webView: WKWebView
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var lastBadge = 0
    @ObservationIgnored private var viewed = false
    @ObservationIgnored private var lastSnapshotAt: Date = .distantPast
    @ObservationIgnored private var pendingScript: String?


    public init(id: String = UUID().uuidString, url: URL) {
        self.id = id
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        info = TileInfo(id: id, kind: .browser, flavor: .web, title: url.host ?? url.absoluteString,
                        subtitle: url.host ?? "", activity: .starting, url: url.absoluteString)
        super.init()
        webView.navigationDelegate = self
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.titleChanged() }
            },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self, let u = view.url else { return }
                    self.info.url = u.absoluteString
                    self.info.subtitle = u.host ?? u.absoluteString
                }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.info.progress = view.isLoading ? view.estimatedProgress : nil
                    self.info.activity = view.isLoading ? .working : (self.info.attention ? self.info.activity : .idle)
                }
            }
        ]
        webView.load(URLRequest(url: url))
    }

    public var url: URL? { webView.url ?? info.url.flatMap(URL.init(string:)) }

    public func setViewed(_ viewed: Bool) {
        self.viewed = viewed
        if viewed { acknowledge() }
    }

    public func acknowledge() {
        info.attention = false
        if info.activity == .done { info.activity = .idle }
    }

    /// Unread counts in titles ("(3) Inbox") are the web's universal "needs you" signal.
    private func titleChanged() {
        let title = webView.title ?? ""
        if !title.isEmpty { info.title = title }
        let badge = Self.badgeCount(in: title)
        if badge > lastBadge, !viewed {
            info.attention = true
            info.activity = .done
            info.detail = "\(badge) new"
            info.lastActivityAt = Date()
        } else if badge == 0 {
            info.detail = nil
        }
        lastBadge = badge
    }

    static func badgeCount(in title: String) -> Int {
        guard title.hasPrefix("("), let close = title.firstIndex(of: ")") else { return 0 }
        return Int(title[title.index(after: title.startIndex)..<close].filter(\.isNumber)) ?? 0
    }

    /// Capture a still, shown in the grid while the live view is borrowed by the expanded panel.
    public func refreshSnapshot(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastSnapshotAt) > 3, webView.window != nil else { return }
        lastSnapshotAt = Date()
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 640
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self, let image else { return }
                self.snapshot = image
                self.mosaic = Self.mosaic(image)
            }
        }
    }

    /// Downsample to wide, short cells; drawn without interpolation, lines of text become bars —
    /// the same look as a terminal's word blocks.
    static func mosaic(_ image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = max(1, cg.width / 16), h = max(1, cg.height / 5)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Keep the page's shape: stretched back to it, the pixels become the wide, short cells.
        return ctx.makeImage().map { NSImage(cgImage: $0, size: image.size) }
    }

    /// Runs `script` once the page has loaded (now, if it already has).
    public func evaluateWhenLoaded(_ script: String) {
        if webView.isLoading || webView.url == nil {
            pendingScript = script
        } else {
            webView.evaluateJavaScript(script)
        }
    }

    public func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }
}

extension BrowserSession: WKNavigationDelegate {
    nonisolated public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            if info.activity == .working || info.activity == .starting { info.activity = .idle }
            // A loaded page clears an earlier load's error; an unread count stays.
            if lastBadge == 0 { info.detail = nil }
            info.lastActivityAt = Date()
            if let script = pendingScript {
                pendingScript = nil
                webView.evaluateJavaScript(script)
            }
            refreshSnapshot(force: true)
        }
    }

    nonisolated public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { loadFailed(error) }
    }

    nonisolated public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { loadFailed(error) }
    }

    /// A load superseded by another (a redirect, a click mid-load) is cancelled, not failed.
    private func loadFailed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        info.activity = .failed
        info.detail = error.localizedDescription
    }
}
