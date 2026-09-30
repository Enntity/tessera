import Foundation

/// Parses Codex rollout files (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`), written by both the
/// Codex CLI and the Codex desktop app.
public struct CodexTranscriptParser: TranscriptParser {
    public private(set) var title: String?
    public private(set) var items: [ConversationItem] = []
    public private(set) var model: String?
    public private(set) var contextTokens: Int?
    public private(set) var lastEventAt: Date?
    public private(set) var cwd: String?
    public private(set) var originator: String?
    public private(set) var sessionId: String?
    /// Guardian reviews and spawned helpers are threads too, but not ones the user started.
    public private(set) var isSubagent = false
    public private(set) var startedAt: Date?
    public private(set) var rateLimits: CodexRateLimits?

    private var turnOpen = false
    private var finished = false
    private var awaitingApproval: String?
    private var finalMessage: String?
    private var runningTool: String?

    /// An open turn this quiet was left open, not working (see TranscriptSupport.openTurnActivity).
    static let openTurnStaleAfter: TimeInterval = 15 * 60

    public init() {}

    public mutating func ingest(line: Substring) {
        guard let obj = TranscriptSupport.object(line),
              let payload = obj["payload"] as? [String: Any] else { return }
        let ts = TranscriptSupport.date(obj["timestamp"])
        let kind = payload["type"] as? String

        switch obj["type"] as? String {
        case "session_meta":
            cwd = payload["cwd"] as? String
            originator = payload["originator"] as? String
            sessionId = payload["id"] as? String ?? payload["session_id"] as? String
            startedAt = TranscriptSupport.date(payload["timestamp"]) ?? ts
            let threadSource = payload["thread_source"] as? String
            isSubagent = (threadSource != nil && threadSource != "user") || (payload["source"] as? [String: Any])?["subagent"] != nil
        case "turn_context":
            model = payload["model"] as? String ?? model
            cwd = payload["cwd"] as? String ?? cwd
        case "response_item":
            if let ts { lastEventAt = ts }
            ingestResponseItem(payload, kind: kind, ts: ts)
        case "event_msg":
            if let ts, kind != "token_count" { lastEventAt = ts }
            ingestEvent(payload, kind: kind, ts: ts)
        default:
            break
        }
    }

    private mutating func ingestResponseItem(_ p: [String: Any], kind: String?, ts: Date?) {
        let id = p["id"] as? String ?? p["call_id"] as? String ?? UUID().uuidString
        switch kind {
        case "message":
            let role = p["role"] as? String
            let text = (p["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            if role == "user", !TranscriptSupport.isInjectedUserText(text) {
                TranscriptSupport.append(.init(id: id, role: .user, text: text, timestamp: ts), to: &items)
            } else if role == "assistant", !text.isEmpty {
                TranscriptSupport.append(.init(id: id, role: .assistant, text: text, timestamp: ts), to: &items)
            }
        case "function_call", "custom_tool_call", "local_shell_call":
            let name = p["name"] as? String ?? "shell"
            let args = p["arguments"] ?? p["input"] ?? p["action"]
            runningTool = name
            TranscriptSupport.append(.init(id: id, role: .tool, text: TranscriptSupport.describeToolInput(args), toolName: name, timestamp: ts), to: &items)
        case "function_call_output", "custom_tool_call_output":
            runningTool = nil
            var text = p["output"] as? String ?? ""
            if let data = text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let inner = o["output"] as? String {
                text = inner
            }
            TranscriptSupport.append(.init(id: id + "-out", role: .toolResult, text: text.preview(200), timestamp: ts), to: &items)
        default:
            break
        }
    }

    private mutating func ingestEvent(_ p: [String: Any], kind: String?, ts: Date?) {
        switch kind {
        case "task_started":
            turnOpen = true
            finished = false
            awaitingApproval = nil
        case "task_complete":
            turnOpen = false
            finished = true
            awaitingApproval = nil
            runningTool = nil
            finalMessage = (p["last_agent_message"] as? String)?.preview(160)
        case "turn_aborted":
            turnOpen = false
            finished = false
            awaitingApproval = nil
            runningTool = nil
        case "exec_approval_request":
            awaitingApproval = "Approve command: " + TranscriptSupport.describeToolInput(p)
        case "apply_patch_approval_request":
            awaitingApproval = "Approve file changes"
        case "request_user_input", "elicitation_request":
            awaitingApproval = "Asking you a question"
        case "exec_command_begin", "exec_command_end", "patch_apply_begin", "patch_apply_end":
            awaitingApproval = nil
        case "token_count":
            if let info = p["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any],
               let input = last["input_tokens"] as? Int {
                contextTokens = input
            }
            if let limits = CodexRateLimits(json: p["rate_limits"], recordedAt: ts ?? Date()) { rateLimits = limits }
        default:
            break
        }
    }

    public func snapshot(now: Date) -> ConversationSnapshot {
        var activity: TileActivity = .idle
        var detail: String?
        if let approval = awaitingApproval {
            activity = .needsInput
            detail = approval
        } else if turnOpen {
            activity = TranscriptSupport.openTurnActivity(lastEventAt: lastEventAt, now: now, staleAfter: Self.openTurnStaleAfter)
            if let tool = runningTool { detail = TranscriptSupport.running(tool) }
        } else if finished {
            activity = .done
            detail = finalMessage
        }
        return ConversationSnapshot(items: items, activity: activity, detail: detail, model: model,
                                    lastEventAt: lastEventAt, contextTokens: contextTokens)
    }
}

/// ChatGPT-plan rate limits Codex reports alongside token counts.
public struct CodexRateLimits: Codable, Hashable, Sendable {
    public struct Window: Codable, Hashable, Sendable {
        public var usedPercent: Double
        public var windowMinutes: Int?
        public var resetsAt: Date?
    }
    public var primary: Window?
    public var secondary: Window?
    public var planType: String?

    /// `resets_in_seconds` is relative to when the event was written, not when we read it.
    init?(json: Any?, recordedAt: Date) {
        guard let obj = json as? [String: Any] else { return nil }
        func window(_ v: Any?) -> Window? {
            guard let w = v as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            var resets: Date?
            if let secs = (w["resets_in_seconds"] as? NSNumber)?.doubleValue { resets = recordedAt.addingTimeInterval(secs) }
            if let at = (w["resets_at"] as? NSNumber)?.doubleValue { resets = Date(timeIntervalSince1970: at) }
            return Window(usedPercent: used, windowMinutes: (w["window_minutes"] as? NSNumber)?.intValue, resetsAt: resets)
        }
        primary = window(obj["primary"])
        secondary = window(obj["secondary"])
        planType = obj["plan_type"] as? String
        if primary == nil && secondary == nil { return nil }
    }
}
