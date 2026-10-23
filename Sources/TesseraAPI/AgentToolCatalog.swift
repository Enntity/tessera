import Foundation

/// Shared discovery: MCP clients can register tools before the app is running.
public enum AgentToolCatalog {
    public struct Tool {
        public let name: String
        public let description: String
        public let properties: [String: [String: Any]]
        public let required: [String]
    }

    public static let version = "1"
    public static let instructions = """
        Tessera is the developer's mission-control board on this Mac: every terminal, AI agent session (Claude, \
        Codex, dsh, …) and LLooM job is a tile. Use it to see what else is running, read another tile, message \
        another agent, or ask the developer something without blocking in a window they may not be watching. \
        Call whoami first to learn your own tile id. Ask the developer only what you genuinely can't decide.
        """

    public static let tools: [Tool] = [
        Tool(name: "board",
             description: "Everything on the board: each tile's id, title, kind, state and a one-line summary, plus the steward's brief of what needs the developer. Start here to discover other agents.",
             properties: ["waiting_only": ["type": "boolean", "description": "Only tiles waiting on the developer."]], required: []),
        Tool(name: "resources",
             description: "The connected LLooM fleet's resources, holders, queues and lease expiry, with freshness status. Read-only: reserve or release through LLooM, never infer ownership from a free snapshot.",
             properties: [:], required: []),
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

}
