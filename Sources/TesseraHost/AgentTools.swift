import Foundation
import TesseraAPI
import TesseraKit

/// What agents can do through Tessera, as MCP tools: see the board and read any tile on it, find
/// themselves, message one another, and ask the user something (answered from the Needs-you lane).
/// Everything read goes out with credentials removed; nothing is read while privacy mode is on.
@MainActor
public final class AgentTools {
    struct Tool {
        let name: String
        let description: String
        let properties: [String: [String: Any]]
        let required: [String]
    }

    static let version = "1"
    static let instructions = """
        Tessera is the developer's mission-control board on this Mac: every terminal, AI agent session (Claude, \
        Codex, dsh, …) and LLooM job is a tile. Use it to see what else is running, read another tile, message \
        another agent, or ask the developer something without blocking in a window they may not be watching. \
        Call whoami first to learn your own tile id. Ask the developer only what you genuinely can't decide.
        """

    static let tools: [Tool] = [
        Tool(name: "board",
             description: "Everything on the board: each tile's id, title, kind, state and a one-line summary, plus the steward's brief of what needs the developer. Start here to discover other agents.",
             properties: ["waiting_only": ["type": "boolean", "description": "Only tiles waiting on the developer."]], required: []),
        Tool(name: "read_tile",
             description: "What a tile shows now: a terminal's screen, a conversation's latest messages, a job's notes. Credentials are removed.",
             properties: ["tile": ["type": "string", "description": "Tile id or exact title (from board)."],
                          "lines": ["type": "integer", "description": "How many lines or messages, default 60."]],
             required: ["tile"]),
        Tool(name: "whoami",
             description: "Which tile you are, as far as Tessera can tell (from TESSERA_TILE_ID or your working folder).",
             properties: [:], required: []),
        Tool(name: "send_message",
             description: "Message another tile's agent. It lands in their inbox; with type=true it is also typed into a terminal agent's prompt (after the developer approves, unless they allow it outright).",
             properties: ["to": ["type": "string", "description": "Tile id or exact title."],
                          "text": ["type": "string"],
                          "type": ["type": "boolean", "description": "Also type it into the recipient's terminal (terminal agents only)."]],
             required: ["to", "text"]),
        Tool(name: "inbox",
             description: "Messages other agents sent you. Waits up to wait_seconds for one to arrive if there are none.",
             properties: ["wait_seconds": ["type": "integer", "description": "0-55, default 0."],
                          "all": ["type": "boolean", "description": "Include ones already read."]],
             required: []),
        Tool(name: "ask_human",
             description: "Ask the developer a question. It appears in Tessera's Needs-you lane, on their phone and as an alert, with your options as one-tap answers. Returns the answer if given within wait_seconds, else an id for get_answer.",
             properties: ["question": ["type": "string"],
                          "options": ["type": "array", "items": ["type": "string"], "description": "Up to 6 short answers."],
                          "wait_seconds": ["type": "integer", "description": "0-55, default 50."]],
             required: ["question"]),
        Tool(name: "get_answer",
             description: "The developer's answer to an ask_human question, waiting up to wait_seconds.",
             properties: ["id": ["type": "string"], "wait_seconds": ["type": "integer", "description": "0-55, default 50."]],
             required: ["id"]),
        Tool(name: "notify_human",
             description: "Leave the developer a short note (a result, a heads-up). It shows in the Needs-you lane until seen. Don't use it for progress chatter.",
             properties: ["text": ["type": "string"]], required: ["text"])
    ]

    private weak var workspace: Workspace?
    /// Privacy mode: the user is showing their screen; nothing is read out.
    public var privacy: () -> Bool = { false }

    public init() {}

    func attach(_ workspace: Workspace) { self.workspace = workspace }

    // MARK: JSON-RPC

    func handle(_ body: Data) async -> (status: Int, body: Data) {
        guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = request["method"] as? String else {
            return (200, Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]]))
        }
        // A notification gets no answer.
        guard let id = request["id"] else { return (202, Data()) }
        let params = request["params"] as? [String: Any] ?? [:]
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch method {
        case "initialize":
            reply["result"] = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                               "capabilities": ["tools": [:]],
                               "serverInfo": ["name": "tessera", "version": Self.version],
                               "instructions": Self.instructions]
        case "ping":
            reply["result"] = [:] as [String: Any]
        case "tools/list":
            reply["result"] = ["tools": Self.tools.map { tool in
                ["name": tool.name, "description": tool.description,
                 "inputSchema": ["type": "object", "properties": tool.properties, "required": tool.required]]
            }]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let meta = params["_meta"] as? [String: Any]
            let caller = (meta?["tessera/caller"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { try? JSONDecoder().decode(AgentCaller.self, from: $0) } ?? AgentCaller()
            do {
                let text = try await call(name, args, caller: caller)
                reply["result"] = ["content": [["type": "text", "text": text]], "isError": false]
            } catch {
                reply["result"] = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
            }
        default:
            reply["error"] = ["code": -32601, "message": "unknown method \(method)"]
        }
        return (200, Self.encode(reply))
    }

    static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    struct Refusal: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // MARK: Tools

    func call(_ name: String, _ args: [String: Any], caller: AgentCaller) async throws -> String {
        guard let workspace else { throw Refusal("Tessera is starting up; try again in a moment.") }
        let me = workspace.agentCaller(caller)
        switch name {
        case "board":
            return board(workspace, waitingOnly: args["waiting_only"] as? Bool ?? false, me: me.tile)
        case "read_tile":
            guard !privacy() else { throw Refusal("The developer has privacy mode on; tiles can't be read right now.") }
            let id = try workspace.resolveTile(args["tile"] as? String ?? "")
            return workspace.readTile(id, lines: max(1, min(400, Self.int(args["lines"]) ?? 60)))
        case "whoami":
            guard let tile = me.tile, let info = workspace.info(tile) else {
                return "Tessera can't tell which tile you are (\(me.reason)). You are \"\(me.label)\". "
                    + "Pass --as NAME (or set TESSERA_AS) to name yourself; others can still message you by tile id once you know it."
            }
            return "You are tile \(tile): \(info.title) (\(info.flavor.displayName), \(info.subtitle))."
        case "send_message":
            let to = try workspace.resolveTile(args["to"] as? String ?? "")
            let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw Refusal("text is empty") }
            guard to != me.tile else { throw Refusal("That is you.") }
            let wantsTyping = args["type"] as? Bool ?? false
            if wantsTyping, workspace.terminals[to] == nil { throw Refusal("Only terminal agents can have messages typed in; it is in their inbox instead.") }
            let title = workspace.info(to)?.title ?? to
            let message = workspace.desk.send(text, from: me.label, fromTile: me.tile, to: to, toTitle: title, type: wantsTyping)
            switch message.delivery {
            case "typed": return "Delivered to \(title): typed into its terminal, and in its inbox."
            case "waiting": return "In \(title)'s inbox. Typing it in waits for the developer's OK in Tessera."
            default: return "In \(title)'s inbox (\(to)). They see it when they check `inbox`."
            }
        case "inbox":
            guard let tile = me.tile else { throw Refusal("Tessera can't tell which tile you are, so it can't find your inbox (\(me.reason)).") }
            let all = args["all"] as? Bool ?? false
            let wait = Self.wait(args["wait_seconds"], default: 0)
            var found = workspace.desk.inbox(for: tile, unreadOnly: !all, markRead: true)
            let deadline = Date().addingTimeInterval(wait)
            while found.isEmpty, Date() < deadline {
                try await Task.sleep(nanoseconds: 500_000_000)
                found = workspace.desk.inbox(for: tile, unreadOnly: !all, markRead: true)
            }
            guard !found.isEmpty else { return "No messages." }
            return found.map { m in
                "[\(m.sentAt.formatted(date: .omitted, time: .shortened))] from \(m.from)\(m.fromTile.map { " (\($0))" } ?? ""): \(m.text)"
            }.joined(separator: "\n")
        case "ask_human":
            let text = (args["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw Refusal("question is empty") }
            let options = (args["options"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let question = workspace.desk.ask(text, options: options, from: me.label, fromTile: me.tile)
            return try await answer(question.id, wait: Self.wait(args["wait_seconds"], default: 50), workspace)
        case "get_answer":
            return try await answer(args["id"] as? String ?? "", wait: Self.wait(args["wait_seconds"], default: 50), workspace)
        case "notify_human":
            let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw Refusal("text is empty") }
            workspace.desk.note(text, from: me.label)
            return "The developer will see it in the Needs-you lane."
        default:
            throw Refusal("unknown tool \(name)")
        }
    }

    private func answer(_ id: String, wait: TimeInterval, _ workspace: Workspace) async throws -> String {
        let deadline = Date().addingTimeInterval(wait)
        while true {
            guard let q = workspace.desk.question(id) else { throw Refusal("no question \(id)") }
            if let answer = q.answer { return "Answer: \(answer)" }
            if q.dismissed { return "The developer set the question aside without answering. Decide yourself, or ask again later." }
            if Date() >= deadline { return "Not answered yet. Question id: \(id). Call get_answer with this id to keep waiting." }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func board(_ workspace: Workspace, waitingOnly: Bool, me: String?) -> String {
        var lines: [String] = []
        if let brief = workspace.steward.brief, workspace.steward.config.enabled {
            lines.append("Brief: \(brief.headline)")
            for item in brief.attention { lines.append("  needs the developer: \(item.id) — \(item.why)") }
        }
        let tiles = workspace.allTiles.filter { !waitingOnly || $0.needsUser }
        lines.append("Tiles (\(tiles.count)):")
        for t in tiles {
            let what = workspace.steward.summaries[t.id]?.summary ?? t.detail ?? ""
            lines.append("- \(t.id)\(t.id == me ? " (you)" : "") | \(t.title) | \(t.flavor.displayName) | \(t.activity.label.lowercased())"
                + "\(t.needsUser ? ", waiting on the developer" : "") | \(t.subtitle)\(what.isEmpty ? "" : " | \(Redactor.redact(what).preview(140))")")
        }
        return lines.joined(separator: "\n")
    }

    static func int(_ value: Any?) -> Int? {
        (value as? Int) ?? (value as? Double).map(Int.init) ?? (value as? String).flatMap { Int($0) }
    }

    /// Waits stay under a minute: some agent harnesses time a tool call out at 60 s.
    static func wait(_ value: Any?, default fallback: Int) -> TimeInterval {
        TimeInterval(max(0, min(55, int(value) ?? fallback)))
    }
}

extension Workspace {
    /// Who is calling: the tile its `TESSERA_TILE_ID` names, else the one agent tile working in its
    /// folder; and the name to show for it.
    func agentCaller(_ caller: AgentCaller) -> (tile: String?, label: String, reason: String) {
        if let tile = caller.tile, exists(tile), let info = info(tile) {
            return (tile, caller.name ?? info.title, "")
        }
        var reason = caller.tile == nil ? "no TESSERA_TILE_ID" : "tile \(caller.tile!) isn't on the board"
        if let cwd = caller.cwd?.standardizedPath {
            let matches = order.filter { id in
                if let t = terminals[id] { return t.isRunning && t.command != nil && (t.liveDirectory() ?? t.cwd).standardizedPath == cwd }
                if let a = agents.session(id) { return a.flavor != .lloom && a.flavor != .agentDesk && a.cwd.standardizedPath == cwd }
                return false
            }
            if matches.count == 1, let info = info(matches[0]) { return (matches[0], caller.name ?? info.title, "") }
            reason += matches.isEmpty ? ", and no agent tile works in \(cwd.abbreviatingHome)"
                : ", and \(matches.count) agent tiles work in \(cwd.abbreviatingHome)"
        }
        let folder = caller.cwd.map { ($0 as NSString).lastPathComponent } ?? "somewhere"
        return (nil, caller.name ?? "an agent in \(folder)", reason)
    }

    /// A tile named by id, or by exact title when only one tile has it.
    func resolveTile(_ ref: String) throws -> String {
        let ref = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else { throw AgentTools.Refusal("Which tile? Give an id or title from board.") }
        if exists(ref) { return ref }
        let titled = allTiles.filter { $0.title.caseInsensitiveCompare(ref) == .orderedSame }
        if titled.count == 1 { return titled[0].id }
        if titled.count > 1 { throw AgentTools.Refusal("\(titled.count) tiles are called \"\(ref)\": \(titled.map(\.id).joined(separator: ", ")). Use an id.") }
        throw AgentTools.Refusal("No tile \"\(ref)\" on the board. Call board for ids.")
    }

    /// What a tile shows, as text: a terminal's screen, a conversation's latest messages.
    func readTile(_ id: String, lines: Int) -> String {
        guard let info = info(id) else { return "" }
        var body: String
        if let t = terminals[id] {
            body = t.terminal.screenTail(t.terminal.rows).joined(separator: "\n").trimmingCharacters(in: .newlines)
        } else if let a = agents.session(id) {
            body = a.snapshot.items.suffix(lines).map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n")
        } else if let b = browsers[id] {
            body = b.info.url ?? ""
        } else {
            body = ""
        }
        let text = body.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
        let head = "\(info.title) | \(info.flavor.displayName) | \(info.activity.label.lowercased()) | \(info.subtitle)"
            + (info.detail.map { "\n\($0)" } ?? "")
        return Redactor.redact(head + "\n---\n" + text)
    }
}
