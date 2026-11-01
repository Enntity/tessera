import Foundation
import TesseraAPI

/// Installs Accord's agent hookup and Tessera's optional native UI tools.
/// Accord owns skills and shared coordination. Retired Tessera skills are archived outside
/// every agent discovery directory, preserving customizations without publishing two contracts.
struct Installer {
    let dryRun: Bool
    var noStart: Bool = false
    let fm = FileManager.default
    let home = URL(fileURLWithPath: NSHomeDirectory())

    var executable: URL {
        let path = CommandLine.arguments[0]
        let url = path.contains("/") ? URL(fileURLWithPath: path) : (Self.which(path) ?? URL(fileURLWithPath: path))
        return url.resolvingSymlinksInPath()
    }

    func say(_ text: String) { print((dryRun ? "would: " : "") + text) }

    func run() throws {
        let bin = home.appendingPathComponent(".local/bin/tessera")
        guard let accord = AccordExecutable.locate() else {
            throw Failure("Accord is required. Install Accord, then rerun tessera install. No Tessera skill was installed.")
        }
        try link(bin, to: executable)
        say("install Accord's skill, startup instructions and MCP connection")
        let (status, output) = Self.run(accord.url, accord.arguments + ["ensure"] + (dryRun ? ["--dry-run"] : []) + (noStart ? ["--no-start"] : []))
        guard status == 0 else { throw Failure("Accord installation failed: \(output)") }
        print(output)
        try retireSkills()

        if let claude = Self.which("claude") {
            let (has, _) = Self.run(claude, ["mcp", "get", "tessera"])
            if has == 0 {
                say("leave Claude Code's tessera MCP server as it is")
            } else {
                say("register MCP server \"tessera\" with Claude Code (user scope)")
                if !dryRun {
                    let (status, output) = Self.run(claude, ["mcp", "add", "--scope", "user", "tessera", "--", bin.path, "mcp"])
                    if status != 0 { throw Failure("claude mcp add failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))") }
                }
            }
        } else {
            say("skip Claude Code: `claude` not found")
        }

        let codex = home.appendingPathComponent(".codex/config.toml")
        if fm.fileExists(atPath: codex.deletingLastPathComponent().path) {
            let exists = fm.fileExists(atPath: codex.path)
            let config = exists ? try String(contentsOf: codex, encoding: .utf8) : ""
            if config.contains("[mcp_servers.tessera]") {
                say("leave Codex's [mcp_servers.tessera] as it is")
            } else {
                say("add [mcp_servers.tessera] to \(codex.path) (backup: config.toml.bak-tessera)")
                if !dryRun {
                    if exists {
                        let backup = codex.appendingPathExtension("bak-tessera-\(UUID().uuidString)")
                        try fm.copyItem(at: codex, to: backup)
                        print("  saved config backup: \(backup.path)")
                    }
                    let quotedPath = bin.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    let block = "\n[mcp_servers.tessera]\ncommand = \"\(quotedPath)\"\nargs = [\"mcp\"]\ntool_timeout_sec = 70\n"
                    try (config + (config.hasSuffix("\n") ? "" : "\n") + block).write(to: codex, atomically: true, encoding: .utf8)
                }
            }
        } else {
            say("skip Codex: no ~/.codex/config.toml")
        }

        if let devin = Self.which("devin") {
            // Devin already reads ~/.agents/skills, so only the MCP server is its own step.
            // `mcp get` is a read: it answers under --dry-run too, so the plan it prints is real.
            let (has, _) = Self.run(devin, ["mcp", "get", "tessera"])
            if has == 0 {
                say("leave Devin's tessera MCP server as it is")
            } else {
                say("register MCP server \"tessera\" with Devin (user scope)")
                if !dryRun {
                    let (status, output) = Self.run(devin, ["mcp", "add", "--scope", "user", "tessera", "--", bin.path, "mcp"])
                    if status != 0 { throw Failure("devin mcp add failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))") }
                }
            }
        } else {
            say("skip Devin: `devin` not found")
        }
        if !(ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains(Substring(bin.deletingLastPathComponent().path)) {
            print("For shell use, add ~/.local/bin to PATH in your shell configuration. MCP uses the absolute path and needs no PATH change.")
        }
        if !dryRun {
            let marker = home.appendingPathComponent(".config/tessera/accord-installed-v1")
            try fm.createDirectory(at:marker.deletingLastPathComponent(),withIntermediateDirectories:true)
            try "Accord skill owns agent coordination.\n".write(to:marker,atomically:true,encoding:.utf8)
        }
        print(dryRun ? "Nothing changed." : "Done. Restart agent sessions to pick up the MCP server and Accord skill.")
    }

    /// Move whole directories (including local customizations) out of skill discovery.
    /// A symlink is archived as a symlink: never follow it and move its external target.
    func retireSkills() throws {
        let archive = home.appendingPathComponent(".config/accord/retired-skills")
        for (client, relative) in [("shared", ".agents/skills"), ("claude", ".claude/skills"), ("codex", ".codex/skills")] {
            let root = home.appendingPathComponent(relative)
            guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names.sorted() where name == "tessera" || name.hasPrefix("tessera.backup-") {
                let source = root.appendingPathComponent(name)
                let target = archive.appendingPathComponent("\(client)-\(name)-\(UUID().uuidString)")
                say("retire Tessera skill → \(target.path)")
                if !dryRun {
                    try fm.createDirectory(at: archive, withIntermediateDirectories: true)
                    try fm.moveItem(at: source, to: target)
                }
            }
        }
    }

    /// A symlink at `path` to `target`, replacing an older symlink but never a real file.
    func link(_ path: URL, to target: URL, relative: String? = nil) throws {
        let destination = relative ?? target.path
        if let existing = try? fm.destinationOfSymbolicLink(atPath: path.path) {
            if existing == destination { return say("keep \(path.path) → \(destination)") }
            say("relink \(path.path) → \(destination)")
            if !dryRun { try fm.removeItem(at: path) }
        } else if fm.fileExists(atPath: path.path) {
            throw Failure("Cannot install at \(path.path): an existing file is there. Move it aside yourself or use manual MCP setup; nothing was overwritten at that path.")
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
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}
