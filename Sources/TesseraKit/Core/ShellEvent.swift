import Foundation

/// What a tile's shell reports to Tessera (OSC 6973): a command line starting (as typed, plus the
/// alias-expanded form when the shell provides it), a return to the prompt, that a resume couldn't
/// pick the old session up and a fresh one was started instead, or that the launched program
/// wasn't there to run at all.
public enum ShellEvent: Equatable, Sendable {
    case command(typed: String, expanded: String?)
    case prompt(status: Int32)
    case startedFresh
    case programMissing

    public static let oscCode = 6973

    /// Payloads: `cmd;<nonce>;<b64 typed>[;<b64 expanded>]`, `done;<nonce>;<status>`, `fresh;<nonce>`,
    /// `missing;<nonce>`.
    /// Reports travel in the terminal's output, so anything printed there (a `cat`ed file, an ssh
    /// session) could imitate one; only reports carrying the tile's secret nonce are believed.
    public static func parse(_ payload: String, nonce: String) -> ShellEvent? {
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !nonce.isEmpty, parts[1] == nonce else { return nil }
        switch parts[0] {
        case "cmd":
            guard parts.count >= 3, let typed = decode(parts[2]) else { return nil }
            let expanded = parts.count >= 4 ? decode(parts[3]) : nil
            return .command(typed: typed, expanded: expanded == typed ? nil : expanded)
        case "done":
            return .prompt(status: Int32(parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : "") ?? 0)
        case "fresh":
            return .startedFresh
        case "missing":
            return .programMissing
        default:
            return nil
        }
    }

    /// A per-tile secret for `parse`.
    public static func makeNonce() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private static func decode(_ b64: String) -> String? {
        guard let data = Data(base64Encoded: b64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let line = String(data: data, encoding: .utf8) else { return nil }
        let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

/// Builds the command line a tile's shell runs at start: the primary command (a resume, or a fresh
/// launch with an assigned id), a fallback if that fails quickly, then an interactive shell.
///
/// Exit status 126/127 means the program wasn't there to run (e.g. not on PATH after a toolchain
/// switch), which says nothing about the conversation: that is reported, never "fixed" by starting
/// fresh. 128 and up is a signal, i.e. the user quit.
public enum LaunchScript {
    public enum Dialect: Sendable { case posix, fish }

    /// Failing within this many seconds means "couldn't start", not "the user quit".
    public static let quickFailure = 20

    /// The dialect `shell` speaks, or nil for shells these scripts aren't written for (tcsh, nu, …).
    public static func dialect(forShell shell: String) -> Dialect? {
        switch (shell as NSString).lastPathComponent {
        case "fish": .fish
        case "zsh", "bash", "sh", "ksh", "mksh": .posix
        default: nil
        }
    }

    public static func build(primary: String, fallback: String?, followUp: String, dialect: Dialect, nonce: String) -> String {
        let fallback = fallback == primary ? nil : fallback
        let note = "\\n\\033[2m[tessera] Could not resume that session; starting a new one.\\033[0m\\n"
        func report(_ event: String) -> String { "printf '\\033]\(ShellEvent.oscCode);\(event);\(nonce)\\007'" }
        switch dialect {
        case .posix:
            let retry = fallback.map {
                "elif [ $__s -ne 0 ] && [ $__s -lt 126 ] && [ $((SECONDS - __t)) -lt \(quickFailure) ]; then printf '\(note)'; \(report("fresh")); \($0); "
            } ?? ""
            return "__t=$SECONDS; \(primary); __s=$?; "
                + "if [ $__s -eq 126 ] || [ $__s -eq 127 ]; then \(report("missing")); \(retry)fi; "
                + followUp
        case .fish:
            let retry = fallback.map {
                "else if test $__s -ne 0 -a $__s -lt 126 -a (math (date +%s) - $__t) -lt \(quickFailure); printf '\(note)'; \(report("fresh")); \($0); "
            } ?? ""
            return "set -l __t (date +%s); \(primary); set -l __s $status; "
                + "if test $__s -eq 126 -o $__s -eq 127; \(report("missing")); \(retry)end; "
                + followUp
        }
    }
}
