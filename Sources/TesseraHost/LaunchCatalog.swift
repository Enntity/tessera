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
        let script = names.map { "command -v \($0) >/dev/null 2>&1 && echo '@found \($0)'" }.joined(separator: "; ")
        guard let output = LoginShell.run(script) else { return known }
        let found = Set(LoginShell.tagged("found", in: output))
        return known.filter { $0.command == nil || found.contains($0.command!) }
    }
}
