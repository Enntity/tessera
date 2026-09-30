import Foundation

/// What Claude Code's own `/usage` panel says about the plan: how much of the current session
/// (5-hour) and the current week (all models) is used, and when each resets. Read from the panel's
/// text, since that is the one place Claude Code shows them without a model reply.
public enum ClaudeUsageScreen {
    public struct Window: Equatable, Sendable {
        public var label: String
        public var usedPercent: Double
        /// As the panel says it, without the time zone ("6:50pm", "Oct 7 at 5am").
        public var resets: String?
    }

    public enum Outcome: Equatable, Sendable {
        case windows([Window])
        /// The panel came up with an error instead (Anthropic refused to say, for now).
        case refused(String)
    }

    /// The panel's two plan windows, once both are on screen; nil while it is still loading.
    public static func parse(_ lines: [String]) -> Outcome? {
        if let refusal = lines.first(where: { $0.localizedCaseInsensitiveContains("rate limited") }) {
            return .refused(refusal.trimmingCharacters(in: .whitespaces))
        }
        let windows = [("Current session", "5h"), ("Current week (all models)", "Week")].compactMap { heading, label -> Window? in
            guard let at = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(heading) }) else { return nil }
            let after = lines[(at + 1)...].prefix(3)
            guard let used = after.lazy.compactMap(percentUsed).first else { return nil }
            return Window(label: label, usedPercent: used, resets: after.lazy.compactMap(resets).first)
        }
        return windows.count == 2 ? .windows(windows) : nil
    }

    /// `████▌     10% used` → 10.
    static func percentUsed(in line: String) -> Double? {
        guard let used = line.range(of: "% used") ?? line.range(of: "%used") else { return nil }
        let digits = line[..<used.lowerBound].reversed().prefix { $0.isNumber || $0 == "." }
        return Double(String(digits.reversed()))
    }

    /// `Resets Oct 7 at 5am (America/Phoenix)` → "Oct 7 at 5am".
    static func resets(in line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("Resets ") else { return nil }
        let when = text.dropFirst("Resets ".count)
        return String(when.range(of: " (").map { when[..<$0.lowerBound] } ?? when)
    }
}
