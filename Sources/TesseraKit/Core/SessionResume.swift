import Foundation

/// How agent CLIs start and resume conversations, so a terminal tile can be shut down and later
/// brought back into the same conversation.
///
/// - Claude Code and Grok accept `--session-id <uuid>` for a new conversation and `--resume <uuid>`,
///   so Tessera assigns the id up front.
/// - Codex has no launch-time id; the host binds the rollout it writes, then uses `codex resume <id>`.
/// - opencode (`-s`) and omp (`-r`) resume by id when known, else continue their latest session.
public enum SessionResume {
    public enum Tool: String, Codable, Sendable { case claude, grok, codex, opencode, omp }

    public static func tool(for command: String) -> Tool? {
        guard let exe = ShellWords.split(command).first else { return nil }
        return Tool(rawValue: (exe as NSString).lastPathComponent.lowercased())
    }

    /// The command to actually run for a fresh launch, and the session id assigned to it (if the tool
    /// lets us choose one). Commands that already pick a session are left alone.
    public static func prepareLaunch(_ command: String, newId: () -> String = { UUID().uuidString.lowercased() })
        -> (command: String, sessionId: String?) {
        guard let tool = tool(for: command) else { return (command, nil) }
        if let existing = sessionId(in: command) { return (command, existing) }
        let words = ShellWords.split(command)
        switch tool {
        case .claude, .grok:
            let busy: Set<String> = ["-c", "--continue", "-r", "--resume", "-p", "--print", "--session-id"]
            guard !words.contains(where: busy.contains) else { return (command, nil) }
            let id = newId()
            return (ShellWords.join(words + ["--session-id", id]), id)
        case .codex, .opencode, .omp:
            return (command, nil)
        }
    }

    /// The id a command line already names (`claude --resume X`, `codex resume X`, `omp -r X`, …).
    public static func sessionId(in command: String) -> String? {
        guard let tool = tool(for: command) else { return nil }
        let words = Array(ShellWords.split(command).dropFirst())
        func value(after flags: Set<String>) -> String? {
            guard let i = words.firstIndex(where: flags.contains), i + 1 < words.count, !words[i + 1].hasPrefix("-") else { return nil }
            return isSafeId(words[i + 1]) ? words[i + 1] : nil
        }
        switch tool {
        case .claude, .grok:
            return value(after: ["--session-id"]) ?? (words.contains("--fork-session") ? nil : value(after: ["--resume", "-r"]))
        case .codex:
            guard words.first == "resume", words.count > 1, !words[1].hasPrefix("-") else { return nil }
            return isSafeId(words[1]) ? words[1] : nil
        case .opencode:
            return value(after: ["-s", "--session"])
        case .omp:
            return value(after: ["-r", "--resume"])
        }
    }

    /// The command that brings `original` back into `sessionId` — or into the tool's most recent
    /// conversation when the id is unknown. Nil means "just run the original command again".
    public static func resumeCommand(original: String, sessionId: String?) -> String? {
        guard let tool = tool(for: original) else { return nil }
        let id = sessionId.flatMap { isSafeId($0) ? $0 : nil }
        var words = ShellWords.split(original)
        let exe = words.removeFirst()
        switch tool {
        case .claude, .grok:
            words = strip(words, flags: ["--resume", "-r", "--session-id"], switches: ["--continue", "-c", "--fork-session"])
            return ShellWords.join([exe] + words + (id.map { ["--resume", $0] } ?? ["--continue"]))
        case .codex:
            if let first = words.first, !first.hasPrefix("-") {
                guard first == "resume" else { return nil }  // `codex exec …` and friends aren't sessions
                words.removeFirst()
                if let next = words.first, !next.hasPrefix("-") { words.removeFirst() }
                words.removeAll { $0 == "--last" }
            }
            return ShellWords.join([exe, "resume"] + (id.map { [$0] } ?? ["--last"]) + words)
        case .opencode:
            words = strip(words, flags: ["-s", "--session"], switches: ["-c", "--continue"])
            return ShellWords.join([exe] + words + (id.map { ["-s", $0] } ?? ["-c"]))
        case .omp:
            words = strip(words, flags: ["-r", "--resume"], switches: ["-c", "--continue"])
            return ShellWords.join([exe] + words + (id.map { ["-r", $0] } ?? ["-c"]))
        }
    }

    /// Session ids are interpolated into shell commands; only plain ids pass.
    public static func isSafeId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private static func strip(_ words: [String], flags: Set<String>, switches: Set<String>) -> [String] {
        var out: [String] = []
        var skipNext = false
        for w in words {
            if skipNext { skipNext = false; if !w.hasPrefix("-") { continue } }
            if flags.contains(w) { skipNext = true; continue }
            if switches.contains(w) { continue }
            out.append(w)
        }
        return out
    }
}

/// Minimal POSIX-shell word handling: enough to edit agent command lines without breaking quoting.
public enum ShellWords {
    public static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for ch in line {
            if escaped { current.append(ch); escaped = false; inWord = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else if ch == "\\", q == "\"" { escaped = true } else { current.append(ch) }
                continue
            }
            switch ch {
            case "'", "\"": quote = ch; inWord = true
            case "\\": escaped = true
            case " ", "\t", "\n":
                if inWord { words.append(current); current = ""; inWord = false }
            default: current.append(ch); inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }

    public static func join(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }

    static func quote(_ word: String) -> String {
        let safe = word.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0) }
        if safe && !word.isEmpty { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
