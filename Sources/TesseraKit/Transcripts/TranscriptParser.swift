import Foundation

/// Incrementally folds an append-only JSONL transcript into a bounded conversation snapshot.
public protocol TranscriptParser {
    mutating func ingest(line: Substring)
    func snapshot(now: Date) -> ConversationSnapshot
    /// A title the transcript itself carries, if any.
    var title: String? { get }
}

public extension TranscriptParser {
    mutating func ingest(text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) { ingest(line: line) }
    }
}

enum TranscriptSupport {
    static let maxItems = 60

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let whole = ISO8601DateFormatter()

    static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return fractional.date(from: s) ?? whole.date(from: s)
    }

    static func object(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Context injected by harnesses (AGENTS.md dumps, system reminders, command wrappers) is not user speech.
    static func isInjectedUserText(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.hasPrefix("<") || t.hasPrefix("# AGENTS.md") || t.hasPrefix("Another Claude session sent a message")
            || t.hasPrefix("Caveat:") || t.hasPrefix("[Request interrupted")
    }

    /// One-line description of a tool call from its arguments.
    static func describeToolInput(_ input: Any?) -> String {
        var dict = input as? [String: Any]
        if dict == nil, let s = input as? String {
            if let data = s.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                dict = parsed
            } else {
                return s.preview(160)
            }
        }
        guard let dict else { return "" }
        for key in ["description", "command", "cmd", "file_path", "path", "pattern", "url", "query", "prompt", "task_name", "message"] {
            if let v = dict[key] as? String, !v.isEmpty { return v.preview(160) }
            if let v = dict[key] as? [String], !v.isEmpty { return v.joined(separator: " ").preview(160) }
        }
        return ""
    }

    static func append(_ item: ConversationItem, to items: inout [ConversationItem]) {
        items.append(item)
        if items.count > maxItems { items.removeFirst(items.count - maxItems) }
    }
}
