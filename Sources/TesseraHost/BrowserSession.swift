import AppKit
import Observation
import TesseraKit
import WebKit

/// A web page as a tile. The WKWebView stays alive (logged-in state, media, scroll); the grid shows
/// periodic snapshots and the expanded panel re-parents the live view.
@Observable
@MainActor
public final class BrowserSession: NSObject {
    public let id: String
    public private(set) var info: TileInfo
    public private(set) var snapshot: NSImage?
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
                if let image { self?.snapshot = image }
            }
        }
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
            info.lastActivityAt = Date()
            if let script = pendingScript {
                pendingScript = nil
                webView.evaluateJavaScript(script)
            }
            refreshSnapshot(force: true)
        }
    }

    nonisolated public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            info.activity = .failed
            info.detail = error.localizedDescription
        }
    }

    nonisolated public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            info.activity = .failed
            info.detail = error.localizedDescription
        }
    }
}
