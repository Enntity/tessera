import Foundation

/// Claude Code hands its status line the plan limits it gets back from Anthropic (`rate_limits`:
/// the five-hour and weekly windows) — the documented way to see them, with no sign-in of its own
/// and nothing extra asked of Anthropic. The tap is a status-line command that records that JSON
/// for Tessera and then runs the status line the user had, so theirs looks as it did.
///
/// Only connected when the user asks (the Claude plan card), since it edits Claude Code's
/// `settings.json`: a copy of the file is kept first, and the status line it replaces is kept
/// beside the tap and put back when it is disconnected.
public struct ClaudeStatusTap: Sendable {
    /// Tessera's data folder: the tap, the status line it wraps, and what it records live here.
    let directory: URL
    /// Claude Code's user settings.
    let settings: URL

    init(directory: URL, settings: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")) {
        self.directory = directory
        self.settings = settings
    }

    var script: URL { directory.appendingPathComponent("claude-statusline.sh") }
    /// The last status JSON that carried plan limits.
    var recorded: URL { directory.appendingPathComponent("claude-status.json") }
    /// The command the tap runs after recording: the status line the user had.
    private var previousCommand: URL { directory.appendingPathComponent("claude-statusline.previous") }
    /// The whole `statusLine` setting it replaced, to put back.
    private var previousSetting: URL { directory.appendingPathComponent("claude-statusline.previous.json") }
    var backup: URL { settings.appendingPathExtension("tessera-backup") }

    private var command: String { "/bin/sh " + Self.quoted(script.path) }

    /// Whether Claude Code's settings run the tap now (another tool may have replaced it since).
    var isConnected: Bool {
        (Self.read(settings)?["statusLine"] as? [String: Any])?["command"] as? String == command
    }

    /// The latest limits recorded, and when.
    func latest() -> (data: Data, at: Date)? {
        guard let data = try? Data(contentsOf: recorded), let at = FileStat(recorded.path)?.modified else { return nil }
        return (data, at)
    }

    /// Puts the tap in Claude Code's settings, keeping the status line that was there.
    func connect() throws {
        var root = Self.read(settings) ?? [:]
        let current = root["statusLine"] as? [String: Any]
        if !isConnected {
            if FileManager.default.fileExists(atPath: settings.path) {
                try? FileManager.default.removeItem(at: backup)
                try FileManager.default.copyItem(at: settings, to: backup)
            }
            try JSONSerialization.data(withJSONObject: current ?? [:]).write(to: previousSetting, options: .atomic)
            try Data(((current?["command"] as? String) ?? "").utf8).write(to: previousCommand, options: .atomic)
        }
        try Data(scriptText.utf8).write(to: script, options: .atomic)
        var line = current ?? [:]
        line["type"] = "command"
        line["command"] = command
        root["statusLine"] = line
        try Self.write(root, to: settings)
    }

    /// Puts back the status line the tap replaced (none, if there was none).
    func disconnect() throws {
        guard var root = Self.read(settings), isConnected else { return }
        let previous = (try? Data(contentsOf: previousSetting)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        root["statusLine"] = previous?.isEmpty == false ? previous : nil
        try Self.write(root, to: settings)
    }

    /// Records the JSON only when it carries plan limits (a session before its first reply, or on an
    /// API key, has none), atomically, then hands it to the previous status line.
    var scriptText: String {
        """
        #!/bin/sh
        # Tessera's Claude Code status-line tap: records the plan limits Claude Code reports, then runs
        # the status line that was configured before (Tessera ▸ Accounts ▸ Claude plan ▸ Disconnect undoes it).
        dir=\(Self.quoted(directory.path))
        input=$(cat)
        case $input in *'"rate_limits"'*)
          printf '%s' "$input" > "$dir/claude-status.json.$$" && mv -f "$dir/claude-status.json.$$" "$dir/claude-status.json" ;;
        esac
        if [ -s "$dir/claude-statusline.previous" ]; then
          printf '%s' "$input" | /bin/sh -c "$(cat "$dir/claude-statusline.previous")"
        fi
        exit 0

        """
    }

    static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func read(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static func write(_ root: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: url, options: .atomic)
    }
}
