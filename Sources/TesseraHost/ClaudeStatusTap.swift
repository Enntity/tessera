import Foundation

/// Tessera once read the Claude plan's limits through Claude Code's status line, by setting it
/// (in Claude Code's `settings.json`, with the user's agreement) to a small script that recorded
/// them and ran the status line the user had. `/usage` is read directly now, so this puts back the
/// status line that was replaced — every other setting as it is — and removes what it left behind.
enum ClaudeStatusTap {
    static func retire(in directory: URL,
                       settings: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")) {
        let script = directory.appendingPathComponent("claude-statusline.sh")
        let previous = directory.appendingPathComponent("claude-statusline.previous.json")
        if var root = read(settings), (root["statusLine"] as? [String: Any])?["command"] as? String == "/bin/sh " + quoted(script.path) {
            let replaced = read(previous)
            root["statusLine"] = replaced?.isEmpty == false ? replaced : nil
            guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                  (try? data.write(to: settings, options: .atomic)) != nil else { return }
        }
        for name in ["claude-statusline.sh", "claude-statusline.previous", "claude-statusline.previous.json", "claude-status.json"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func read(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}
