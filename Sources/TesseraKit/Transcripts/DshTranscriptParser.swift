import Foundation

/// Parses DeepSeek Harness (dsh) session logs — the decompressed JSONL events in
/// `~/.dsh/sessions/<folder>/<session>/session.vN.jsonl.zstd`.
public struct DshTranscriptParser: TranscriptParser {
    public private(set) var title: String?
    public private(set) var items: [ConversationItem] = []
    public private(set) var model: String?
    public private(set) var lastEventAt: Date?
    public private(set) var cwd: String?
    public private(set) var sessionId: String?
    /// Sessions a parent agent delegated to (subagents) aren't shown as their own tiles.
    public private(set) var isDelegated = false

    private var turnOpen = false
    private var lastTurnEnd: String?
    private var approvals: [String: String] = [:]
    private var pendingTools: [String: (name: String, at: Date)] = [:]

    /// An open turn this quiet was left open, not working (see TranscriptSupport.openTurnActivity).
    static let openTurnStaleAfter: TimeInterval = 15 * 60

    public init() {}

    public mutating func ingest(line: Substring) {
        guard let obj = TranscriptSupport.object(line), let type = obj["type"] as? String else { return }
        let data = obj["data"] as? [String: Any] ?? [:]
        let ts = (obj["time"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        let seq = (obj["seq"] as? NSNumber)?.stringValue ?? UUID().uuidString

        switch type {
        case "session":
            sessionId = obj["id"] as? String
            cwd = obj["cwd"] as? String
            isDelegated = ((obj["delegationDepth"] as? NSNumber)?.intValue ?? 0) > 0
            lastEventAt = (obj["createdAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        case "session/title":
            if let t = data["title"] as? String, !t.isEmpty { title = t }
        case "model/selection":
            model = data["model"] as? String ?? model
        case "user/message":
            // Only what the person typed; reminders and runtime context carry other sources.
            guard (data["source"] as? [String: Any])?["kind"] as? String == "user" else { return }
            let text = Self.text(data["content"])
            guard !text.isEmpty else { return }
            touch(ts)
            TranscriptSupport.append(.init(id: seq, role: .user, text: text, timestamp: ts), to: &items)
        case "assistant/message":
            touch(ts)
            let message = data["message"] as? [String: Any]
            let text = Self.text(message?["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                TranscriptSupport.append(.init(id: seq, role: .assistant, text: text, timestamp: ts), to: &items)
            }
        case "tool/call":
            touch(ts)
            let name = data["name"] as? String ?? "tool"
            if let id = data["callId"] as? String { pendingTools[id] = (name, ts ?? Date()) }
            TranscriptSupport.append(.init(id: seq, role: .tool, text: TranscriptSupport.describeToolInput(data["arguments"]),
                                           toolName: name, timestamp: ts), to: &items)
        case "tool/result":
            touch(ts)
            let message = data["message"] as? [String: Any]
            let callId = message?["toolCallId"] as? String
            let name = callId.flatMap { pendingTools.removeValue(forKey: $0)?.name }
            TranscriptSupport.append(.init(id: seq, role: .toolResult, text: Self.text(message?["content"]).preview(200),
                                           toolName: name, isError: message?["isError"] as? Bool ?? false, timestamp: ts), to: &items)
        case "approval/asked":
            touch(ts)
            guard let id = data["id"] as? String else { return }
            let tool = data["toolName"] as? String ?? "a tool"
            let reason = (data["reason"] as? String).map { ": " + $0.preview(100) } ?? ""
            approvals[id] = "Approve \(tool)\(reason)"
        case "approval/decided":
            touch(ts)
            if let id = data["id"] as? String { approvals[id] = nil }
        case "turn/start":
            touch(ts)
            turnOpen = true
            lastTurnEnd = nil
        case "turn/end":
            touch(ts)
            turnOpen = false
            approvals.removeAll()
            pendingTools.removeAll()
            lastTurnEnd = (data["reason"] as? [String: Any])?["kind"] as? String ?? "completed"
        default:
            break
        }
    }

    private mutating func touch(_ ts: Date?) {
        if let ts { lastEventAt = ts }
    }

    public func snapshot(now: Date) -> ConversationSnapshot {
        var activity: TileActivity = .idle
        var detail: String?
        if let ask = approvals.values.sorted().first {
            activity = .needsInput
            detail = ask
        } else if turnOpen {
            activity = TranscriptSupport.openTurnActivity(lastEventAt: lastEventAt, now: now, staleAfter: Self.openTurnStaleAfter)
            if let tool = pendingTools.values.min(by: { $0.at < $1.at }) {
                detail = TranscriptSupport.running(tool.name, since: tool.at, now: now)
            }
        } else if let end = lastTurnEnd {
            activity = end == "completed" ? .done : .idle
            if end != "completed" { detail = "Turn \(end)" }
        }
        return ConversationSnapshot(items: items, activity: activity, detail: detail, model: model, lastEventAt: lastEventAt)
    }

    /// Joins the text blocks of a content array (reasoning and tool-call blocks are skipped).
    static func text(_ content: Any?) -> String {
        if let s = content as? String { return s }
        return (content as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}
