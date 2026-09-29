import Foundation

/// Parses Claude Code session transcripts (`~/.claude/projects/<slug>/<session>.jsonl`), which both
/// the CLI and the Claude desktop app write.
public struct ClaudeTranscriptParser: TranscriptParser {
    public private(set) var title: String?
    public private(set) var items: [ConversationItem] = []
    public private(set) var model: String?
    public private(set) var contextTokens: Int?
    public private(set) var lastEventAt: Date?
    public private(set) var cwd: String?

    private var pending: [String: (name: String, since: Date)] = [:]
    private var turnOpen = false
    private var lastStop: String?
    /// Background subagents launched and not yet reported finished, in launch order.
    private var subagents: [(id: String, description: String)] = []

    /// Tools that only ever block on a human.
    static let userDirectedTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]
    /// Tools that finish instantly unless they are waiting for approval.
    static let instantTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit", "Read", "Glob", "Grep"]
    static let approvalGrace: TimeInterval = 20
    /// A tool pending this long belongs to an abandoned session, not a live one.
    static let abandonedAfter: TimeInterval = 30 * 60

    public init() {}

    public mutating func ingest(line: Substring) {
        guard let obj = TranscriptSupport.object(line) else { return }
        let type = obj["type"] as? String
        let ts = TranscriptSupport.date(obj["timestamp"])
        if let cwd = obj["cwd"] as? String { self.cwd = cwd }

        switch type {
        case "custom-title":
            title = obj["customTitle"] as? String ?? title
        case "user":
            guard obj["isSidechain"] as? Bool != true else { return }
            if let ts { lastEventAt = ts }
            ingestUser(obj, ts: ts)
        case "assistant":
            guard obj["isSidechain"] as? Bool != true else { return }
            if let ts { lastEventAt = ts }
            ingestAssistant(obj, ts: ts)
        default:
            break
        }
    }

    private mutating func ingestUser(_ obj: [String: Any], ts: Date?) {
        guard let message = obj["message"] as? [String: Any] else { return }
        let uuid = obj["uuid"] as? String ?? UUID().uuidString
        if let launch = obj["toolUseResult"] as? [String: Any], launch["status"] as? String == "async_launched",
           let id = launch["agentId"] as? String, !subagents.contains(where: { $0.id == id }) {
            subagents.append((id, launch["description"] as? String ?? "subagent"))
        }
        if let text = message["content"] as? String {
            noteTaskNotification(text)
            guard obj["isMeta"] as? Bool != true, !TranscriptSupport.isInjectedUserText(text) else { return }
            beginTurn()
            TranscriptSupport.append(.init(id: uuid, role: .user, text: text, timestamp: ts), to: &items)
            return
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return }
        for (i, block) in blocks.enumerated() {
            switch block["type"] as? String {
            case "tool_result":
                let id = block["tool_use_id"] as? String ?? ""
                let name = pending.removeValue(forKey: id)?.name
                let text = Self.resultText(block["content"])
                TranscriptSupport.append(.init(id: "\(uuid)-\(i)", role: .toolResult, text: text.preview(200), toolName: name,
                                               isError: block["is_error"] as? Bool ?? false, timestamp: ts), to: &items)
            case "text":
                let text = block["text"] as? String ?? ""
                noteTaskNotification(text)
                guard obj["isMeta"] as? Bool != true, !TranscriptSupport.isInjectedUserText(text) else { continue }
                beginTurn()
                TranscriptSupport.append(.init(id: "\(uuid)-\(i)", role: .user, text: text, timestamp: ts), to: &items)
            default:
                break
            }
        }
    }

    private mutating func ingestAssistant(_ obj: [String: Any], ts: Date?) {
        guard let message = obj["message"] as? [String: Any] else { return }
        let uuid = obj["uuid"] as? String ?? UUID().uuidString
        if let m = message["model"] as? String, !m.hasPrefix("<") { model = m }
        if let usage = message["usage"] as? [String: Any] {
            let total = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                .compactMap { usage[$0] as? Int }.reduce(0, +)
            if total > 0 { contextTokens = total }
        }
        let blocks = message["content"] as? [[String: Any]] ?? []
        for (i, block) in blocks.enumerated() {
            switch block["type"] as? String {
            case "text":
                let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    TranscriptSupport.append(.init(id: "\(uuid)-\(i)", role: .assistant, text: text, timestamp: ts), to: &items)
                }
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                if let id = block["id"] as? String { pending[id] = (name, ts ?? Date()) }
                TranscriptSupport.append(.init(id: "\(uuid)-\(i)", role: .tool, text: TranscriptSupport.describeToolInput(block["input"]),
                                               toolName: name, timestamp: ts), to: &items)
            default:
                break
            }
        }
        if let stop = message["stop_reason"] as? String {
            lastStop = stop
            if stop == "end_turn" || stop == "stop_sequence" || stop == "max_tokens" || stop == "refusal" {
                turnOpen = false
                pending.removeAll()
            }
        }
    }

    /// `<task-notification>` reports a background task stopping; any status but running means done.
    private mutating func noteTaskNotification(_ text: String) {
        guard !subagents.isEmpty, text.hasPrefix("<task-notification>"),
              let id = Self.tag("task-id", in: text), Self.tag("status", in: text) != "running" else { return }
        subagents.removeAll { $0.id == id }
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    private mutating func beginTurn() {
        turnOpen = true
        lastStop = nil
    }

    private static func resultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
        }
        return ""
    }

    public func snapshot(now: Date) -> ConversationSnapshot { snapshot(now: now, subagentActivity: nil) }

    /// `subagentActivity` is when a background subagent last wrote its own transcript, which keeps
    /// a session with long-running subagents alive after its main transcript goes quiet.
    public func snapshot(now: Date, subagentActivity: Date?) -> ConversationSnapshot {
        var activity: TileActivity = .idle
        var detail: String?
        if let (name, since) = pending.values.min(by: { $0.since < $1.since }),
           now.timeIntervalSince(lastEventAt ?? since) < Self.abandonedAfter {
            let age = now.timeIntervalSince(since)
            if Self.userDirectedTools.contains(name) {
                activity = .needsInput
                detail = name == "AskUserQuestion" ? "Asking you a question" : "Plan ready for review"
            } else if Self.instantTools.contains(name), age > Self.approvalGrace {
                activity = .needsInput
                detail = "Waiting to approve \(name)"
            } else {
                activity = .working
                detail = "Running \(name) · \(Self.format(age))"
            }
        } else if turnOpen {
            let stale = lastEventAt.map { now.timeIntervalSince($0) > 600 } ?? true
            activity = stale ? .idle : .working
        } else if !subagents.isEmpty,
                  let last = [lastEventAt, subagentActivity].compactMap({ $0 }).max(),
                  now.timeIntervalSince(last) < Self.abandonedAfter {
            activity = .working
            detail = "Waiting on " + (subagents.count == 1 ? subagents[0].description : "\(subagents.count) subagents")
        } else if let sub = subagentActivity, sub > lastEventAt ?? .distantPast, now.timeIntervalSince(sub) < 120 {
            // A subagent launched before the part of the transcript we read is still writing.
            activity = .working
            detail = "Waiting on subagents"
        } else if lastStop != nil {
            activity = .done
        }
        return ConversationSnapshot(items: items, activity: activity, detail: detail, model: model,
                                    lastEventAt: lastEventAt, contextTokens: contextTokens)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}
