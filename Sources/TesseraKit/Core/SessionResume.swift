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

    /// A simple command line split into what precedes the program (`FOO=1`, `env`, `command`, …)
    /// and the program with its arguments. Compound lines (pipes, `&&`, `;`, redirections,
    /// substitutions) aren't invocations Tessera can safely re-run, so they yield nil.
    struct Invocation {
        var prefix: [String]
        var words: [String]
        var exe: String { words[0] }
        var name: String { (exe as NSString).lastPathComponent.lowercased() }

        init?(_ line: String) {
            if line.contains(where: { ";|&<>`\n".contains($0) }) || line.contains("$(") { return nil }
            var all = ShellWords.split(line)
            var prefix: [String] = []
            let wrappers: Set<String> = ["command", "exec", "noglob", "nocorrect", "builtin", "nohup", "env"]
            while let first = all.first, wrappers.contains(first) || Self.isAssignment(first) {
                prefix.append(all.removeFirst())
            }
            guard !all.isEmpty else { return nil }
            self.prefix = prefix
            self.words = all
        }

        static func isAssignment(_ w: String) -> Bool {
            guard let eq = w.firstIndex(of: "="), eq != w.startIndex else { return false }
            let key = w[..<eq]
            return key.first.map { $0.isLetter || $0 == "_" } == true && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }

        func joined(_ words: [String]) -> String { ShellWords.join(prefix + words) }
    }

    /// The agent CLI a command runs. Launchers named after their tool count too (`codex-work`,
    /// `claude_work`): they are expected to pass extra arguments through, so resume flags work.
    public static func tool(for command: String) -> Tool? {
        guard let inv = Invocation(command) else { return nil }
        return tool(named: inv.name)
    }

    static func tool(named name: String) -> Tool? {
        if let exact = Tool(rawValue: name) { return exact }
        return [Tool.claude, .codex, .grok, .opencode, .omp].first { name.hasPrefix($0.rawValue + "-") || name.hasPrefix($0.rawValue + "_") }
    }

    /// True when the command runs the tool's own binary (not a launcher that might not forward
    /// extra arguments), so adding flags like `--session-id` is safe.
    static func isDirect(_ inv: Invocation) -> Bool { Tool(rawValue: inv.name) != nil }

    /// The command to actually run for a fresh launch, and the session id assigned to it (if the tool
    /// lets us choose one). Commands that already pick a session, and launchers, are left alone.
    public static func prepareLaunch(_ command: String, newId: () -> String = { UUID().uuidString.lowercased() })
        -> (command: String, sessionId: String?) {
        guard let inv = Invocation(command), let tool = tool(named: inv.name) else { return (command, nil) }
        if let existing = sessionId(in: command) { return (command, existing) }
        switch tool {
        case .claude, .grok:
            let busy: Set<String> = ["-c", "--continue", "-r", "--resume", "-p", "--print", "--session-id"]
            guard isDirect(inv), !inv.words.contains(where: busy.contains) else { return (command, nil) }
            let id = newId()
            return (inv.joined(inv.words + ["--session-id", id]), id)
        case .codex, .opencode, .omp:
            return (command, nil)
        }
    }

    /// The id a command line already names (`claude --resume X`, `codex resume X`, `omp -r X`, …).
    public static func sessionId(in command: String) -> String? {
        guard let inv = Invocation(command), let tool = tool(named: inv.name) else { return nil }
        let words = Array(inv.words.dropFirst())
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
        guard let inv = Invocation(original), let tool = tool(named: inv.name) else { return nil }
        let id = sessionId.flatMap { isSafeId($0) ? $0 : nil }
        let args = Array(inv.words.dropFirst())
        // `codex exec …` and friends aren't sessions.
        if tool == .codex, let first = args.first, !first.hasPrefix("-"), first != "resume" { return nil }
        let words = withoutSession(tool, args)
        switch tool {
        case .claude, .grok: return inv.joined([inv.exe] + words + (id.map { ["--resume", $0] } ?? ["--continue"]))
        case .codex: return inv.joined([inv.exe, "resume"] + (id.map { [$0] } ?? ["--last"]) + words)
        case .opencode: return inv.joined([inv.exe] + words + (id.map { ["-s", $0] } ?? ["-c"]))
        case .omp: return inv.joined([inv.exe] + words + (id.map { ["-r", $0] } ?? ["-c"]))
        }
    }

    /// A fresh start: the original command without any session selection. For direct Claude/Grok it
    /// reclaims `sessionId` when given (an id assigned but never saved).
    public static func freshLaunch(original: String, sessionId: String? = nil) -> String? {
        guard let inv = Invocation(original), let tool = tool(named: inv.name) else { return nil }
        var words = withoutSession(tool, Array(inv.words.dropFirst()))
        if tool == .claude || tool == .grok, let sessionId, isSafeId(sessionId), isDirect(inv) { words += ["--session-id", sessionId] }
        return inv.joined([inv.exe] + words)
    }

    /// Commands that deliberately pick up the latest conversation (`claude -c`, `codex resume --last`).
    public static func continuesLatest(_ command: String) -> Bool {
        guard let inv = Invocation(command), let tool = tool(named: inv.name) else { return false }
        let words = inv.words.dropFirst()
        switch tool {
        case .claude, .grok, .opencode, .omp: return words.contains("-c") || words.contains("--continue")
        case .codex: return words.first == "resume" && words.contains("--last")
        }
    }

    /// A tool's arguments without any session selection: its resume and continue flags, and for
    /// Codex a leading `resume [<id>]` and `--last`.
    private static func withoutSession(_ tool: Tool, _ words: [String]) -> [String] {
        switch tool {
        case .claude, .grok:
            return strip(words, flags: ["--resume", "-r", "--session-id"], switches: ["--continue", "-c", "--fork-session"])
        case .codex:
            guard words.first == "resume" else { return words }
            var rest = words.dropFirst()
            if let next = rest.first, !next.hasPrefix("-") { rest = rest.dropFirst() }
            return rest.filter { $0 != "--last" }
        case .opencode:
            return strip(words, flags: ["-s", "--session"], switches: ["-c", "--continue"])
        case .omp:
            return strip(words, flags: ["-r", "--resume"], switches: ["-c", "--continue"])
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
