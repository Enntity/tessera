import Foundation
import TesseraAPI
import TesseraKit

/// What agents can do through Tessera, as MCP tools: see the board and read any tile on it, find
/// themselves, message one another, and ask the user something (answered from the Needs-you lane).
/// Everything read goes out with credentials removed; nothing is read while privacy mode is on.
@MainActor
public final class AgentTools {
    static let version = AgentToolCatalog.version
    static let instructions = AgentToolCatalog.instructions
    static let tools = AgentToolCatalog.tools

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
            let caller = (meta?["tessera/caller"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
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
        if privacy(), ["board", "resources", "read_tile", "whoami", "inbox", "get_answer"].contains(name) {
            throw Refusal("The developer has privacy mode on; board content can't be read right now.")
        }
        switch name {
        case "board":
            return board(workspace, waitingOnly: args["waiting_only"] as? Bool ?? false, me: me.tile)
        case "resources":
            return workspace.fleet.agentReport()
        case "read_tile":
            guard !privacy() else { throw Refusal("The developer has privacy mode on; tiles can't be read right now.") }
            let id = try workspace.resolveTile(args["tile"] as? String ?? "")
            return workspace.readTile(id, lines: max(1, min(400, Self.int(args["lines"]) ?? 60)))
        case "whoami":
            guard let tile = me.tile, let info = workspace.info(tile) else {
                return Redactor.redact("Tessera can't tell which tile you are (\(me.reason)). You are \"\(me.label)\". "
                    + "Use board to find your tile, then set TESSERA_TILE_ID to that exact id for inbox access. --as NAME only sets your display name.")
            }
            return Redactor.redact("You are tile \(tile): \(info.title) (\(info.flavor.displayName), \(info.subtitle)).")
        case "send_message":
            let to = try workspace.resolveTile(args["to"] as? String ?? "")
            let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw Refusal("text is empty") }
            guard to != me.tile else { throw Refusal("That is you.") }
            let wantsTyping = args["type"] as? Bool ?? false
            if wantsTyping, workspace.terminals[to] == nil { throw Refusal("Only terminal agents can have messages typed in. Nothing was sent; retry without --type for inbox delivery.") }
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
                guard !privacy() else { throw Refusal("Privacy mode is on; inbox reading paused.") }
                found = workspace.desk.inbox(for: tile, unreadOnly: !all, markRead: true)
            }
            guard !found.isEmpty else { return "No messages." }
            return Redactor.redact(found.map { m in
                "[\(m.sentAt.formatted(date: .omitted, time: .shortened))] from \(m.from)\(m.fromTile.map { " (\($0))" } ?? ""): \(m.text)"
            }.joined(separator: "\n"))
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
            guard !privacy() else { throw Refusal("Privacy mode is on; answer reading paused.") }
            guard let q = workspace.desk.question(id) else { throw Refusal("no question \(id)") }
            if let answer = q.answer { return Redactor.redact("Answer: \(answer)") }
            if q.dismissed { return "The developer set the question aside without answering. This is not approval; leave any action requiring approval pending." }
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
        return Redactor.redact(lines.joined(separator: "\n"))
    }

    static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(exactly: value) }
        return (value as? String).flatMap(Int.init)
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
