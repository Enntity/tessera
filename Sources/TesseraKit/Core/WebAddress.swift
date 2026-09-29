import Foundation

/// Turns what someone typed or pasted into a URL for a web tile.
public enum WebAddress {
    /// True when `text` reads as an address rather than a search.
    public static func looksLikeAddress(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return false }
        if s.contains("://") { return true }
        let host = hostPart(of: s)
        return isLocal(host) || (host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix("."))
    }

    /// Local and private hosts (dev servers, harnesses like `dsh web`) get http; everything else https;
    /// anything that isn't an address becomes a web search.
    public static func normalize(_ text: String) -> URL? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.contains("://") { return URL(string: s) }
        if looksLikeAddress(s) { return URL(string: (isLocal(hostPart(of: s)) ? "http://" : "https://") + s) }
        var c = URLComponents(string: "https://www.google.com/search")
        c?.queryItems = [URLQueryItem(name: "q", value: s)]
        return c?.url
    }

    /// `127.0.0.1:3080/?token=x` → `127.0.0.1`; `[::1]:8080` → `::1`.
    static func hostPart(of s: String) -> String {
        var authority = String(s.prefix { !"/?#".contains($0) })
        if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            return String(authority[authority.index(after: authority.startIndex)..<close])
        }
        return String(authority.prefix { $0 != ":" }).lowercased()
    }

    static func isLocal(_ host: String) -> Bool {
        if ["localhost", "0.0.0.0", "::1"].contains(host) || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.hasSuffix(".test") || host.hasSuffix(".internal") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, host.split(separator: ".").count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true  // CGNAT, e.g. Tailscale
        default: return false
        }
    }
}
