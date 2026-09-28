import Foundation
import Observation
import TesseraKit

public enum LaunchCatalog {
    public static let known: [LaunchPreset] = [
        LaunchPreset(name: "Shell", command: nil, flavor: .shell),
        LaunchPreset(name: "Claude Code", command: "claude", flavor: .claude),
        LaunchPreset(name: "Codex", command: "codex", flavor: .codex),
        LaunchPreset(name: "Grok", command: "grok", flavor: .grok),
        LaunchPreset(name: "Gemini", command: "gemini", flavor: .gemini),
        LaunchPreset(name: "omp", command: "omp", flavor: .omp),
        LaunchPreset(name: "opencode", command: "opencode", flavor: .opencode),
        LaunchPreset(name: "aider", command: "aider", flavor: .aider)
    ]

    /// Which agent CLIs are on the user's login-shell PATH. Runs a shell, so call off the main thread.
    public static func detectInstalled() -> [LaunchPreset] {
        let names = known.compactMap(\.command)
        let script = names.map { "command -v \($0) >/dev/null 2>&1 && echo \($0)" }.joined(separator: "; ")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-l", "-i", "-c", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return known }
        p.waitUntilExit()
        let found = Set(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init))
        return known.filter { $0.command == nil || found.contains($0.command!) }
    }
}
