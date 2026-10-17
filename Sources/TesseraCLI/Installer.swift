import Foundation

/// `tessera install`: makes Tessera reachable from every agent on this Mac.
/// - `~/.local/bin/tessera` points at this command;
/// - the skills shipped beside it go to `~/.agents/skills` (read by Codex and other agents), linked
///   from `~/.claude/skills` for Claude Code;
/// - `tessera mcp` is registered as an MCP server with Claude Code (`claude mcp add --scope user`)
///   and Codex (`[mcp_servers.tessera]` in `~/.codex/config.toml`, backed up first).
/// Each step says what it did; `--dry-run` only says what it would do.
struct Installer {
    let dryRun: Bool
    let fm = FileManager.default
    let home = URL(fileURLWithPath: NSHomeDirectory())

    var executable: URL {
        let path = CommandLine.arguments[0]
        let url = path.contains("/") ? URL(fileURLWithPath: path) : (Self.which(path) ?? URL(fileURLWithPath: path))
        return url.resolvingSymlinksInPath()
    }

    /// Beside the command in the app (Contents/Helpers → Contents/Resources/skills), or in a
    /// source checkout (.build/<config>/ → skills/).
    var skillsSource: URL? {
        let dir = executable.deletingLastPathComponent()
        let candidates = [ProcessInfo.processInfo.environment["TESSERA_SKILLS_DIR"].map { URL(fileURLWithPath: $0) },
                          dir.appendingPathComponent("../Resources/skills"),
                          dir.appendingPathComponent("../../skills"),
                          dir.appendingPathComponent("../../../skills")].compactMap { $0 }
        return candidates.map(\.standardizedFileURL).first { fm.fileExists(atPath: $0.appendingPathComponent("tessera/SKILL.md").path) }
    }

    func say(_ text: String) { print((dryRun ? "would: " : "") + text) }

    func run() throws {
        let bin = home.appendingPathComponent(".local/bin/tessera")
        try link(bin, to: executable)

        if let source = skillsSource {
            for name in try fm.contentsOfDirectory(atPath: source.path).sorted() where !name.hasPrefix(".") {
                let target = home.appendingPathComponent(".agents/skills/\(name)")
                say("install skill \(name) → \(target.path)")
                if !dryRun {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.copyItem(at: source.appendingPathComponent(name), to: target)
                }
                try link(home.appendingPathComponent(".claude/skills/\(name)"), to: target, relative: "../../.agents/skills/\(name)")
            }
        } else {
            say("skip skills: none found beside \(executable.path) (set TESSERA_SKILLS_DIR)")
        }

        if let claude = Self.which("claude") {
            say("register MCP server \"tessera\" with Claude Code (user scope)")
            if !dryRun {
                _ = Self.run(claude, ["mcp", "remove", "--scope", "user", "tessera"])
                let (status, output) = Self.run(claude, ["mcp", "add", "--scope", "user", "tessera", "--", bin.path, "mcp"])
                if status != 0 { print("  claude mcp add failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))") }
            }
        } else {
            say("skip Claude Code: `claude` not found")
        }

        let codex = home.appendingPathComponent(".codex/config.toml")
        if let config = try? String(contentsOf: codex, encoding: .utf8) {
            if config.contains("[mcp_servers.tessera]") {
                say("leave Codex's [mcp_servers.tessera] as it is")
            } else {
                say("add [mcp_servers.tessera] to \(codex.path) (backup: config.toml.bak-tessera)")
                if !dryRun {
                    try? fm.removeItem(at: codex.appendingPathExtension("bak-tessera"))
                    try fm.copyItem(at: codex, to: URL(fileURLWithPath: codex.path + ".bak-tessera"))
                    let block = "\n[mcp_servers.tessera]\ncommand = \"\(bin.path)\"\nargs = [\"mcp\"]\ntool_timeout_sec = 70\n"
                    try (config + (config.hasSuffix("\n") ? "" : "\n") + block).write(to: codex, atomically: true, encoding: .utf8)
                }
            }
        } else {
            say("skip Codex: no ~/.codex/config.toml")
        }
        print(dryRun ? "Nothing changed." : "Done. Restart agent sessions to pick up the MCP server and skills.")
    }

    /// A symlink at `path` to `target`, replacing an older symlink but never a real file.
    func link(_ path: URL, to target: URL, relative: String? = nil) throws {
        let destination = relative ?? target.path
        if let existing = try? fm.destinationOfSymbolicLink(atPath: path.path) {
            if existing == destination { return say("keep \(path.path) → \(destination)") }
            say("relink \(path.path) → \(destination)")
            if !dryRun { try fm.removeItem(at: path) }
        } else if fm.fileExists(atPath: path.path) {
            return say("leave \(path.path): it is a real file, not a link Tessera made")
        } else {
            say("link \(path.path) → \(destination)")
        }
        guard !dryRun else { return }
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: path.path, withDestinationPath: destination)
    }

    static func which(_ name: String) -> URL? {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "") + ":\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin"
        return path.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func run(_ tool: URL, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
