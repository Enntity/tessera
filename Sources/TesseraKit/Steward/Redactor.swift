import Foundation

/// Takes credentials out of text before it leaves the board: to the steward's model, or to an agent
/// reading another tile. Terminals show keys and tokens all the time; none of them is ever needed to
/// say what a tile is doing.
public enum Redactor {
    private static let patterns: [NSRegularExpression] = [
        // PEM private keys, whole.
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
        // Provider keys and tokens by their shape.
        #"\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{16,}"#,
        #"\blloom_[a-z]+_[0-9a-f]{16,}"#,
        #"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#,
        #"\bxox[abposr]-[A-Za-z0-9-]{10,}"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\bAIza[0-9A-Za-z_-]{35}"#,
        #"\b(?:r8|hf|jina|xai)_[A-Za-z0-9]{20,}"#,
        // JSON web tokens.
        #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// `Authorization: Bearer …`, `API_KEY=…`, `password: …`: the label stays, the value goes.
    private static let labelled = try? NSRegularExpression(
        pattern: #"(?i)\b((?:authorization:\s*)?bearer\s+|(?:[A-Z0-9_]*(?:api[_-]?key|token|secret|password|passwd))\s*[:=]\s*["']?)([^\s"']{6,})"#)

    public static func redact(_ text: String) -> String {
        var out = text
        for pattern in patterns {
            out = pattern.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "[secret]")
        }
        if let labelled {
            out = labelled.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1[secret]")
        }
        return out
    }
}
