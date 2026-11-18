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
        Tessera provides optional native UI inspection on this Mac. Use Accord for session discovery, \
        messages, questions, summaries, search and resource reservations. No Tessera skill or separate \
        enrollment is needed. These tools inspect Tessera's visible board and native terminal screens. \
        send_to_tile delivers a message into a tile's prompt once it sits idle — accord_send with \
        delivery "native-prompt" to the tile's Accord address does the same. close_tile closes an \
        idle tile the way the developer would, or asks the developer when it's busy. open_tile starts \
        a new shell or agent tile, or brings a closed one back.
        """

    public static let tools: [Tool] = [
        Tool(name: "board",
             description: "Everything on the board: each tile's id, title, kind, state, the Accord address of its session and a one-line summary with its age, plus the steward's brief of what needs the developer. Use Accord to discover collaborators across hosts.",
             properties: ["waiting_only": ["type": "boolean", "description": "Only tiles waiting on the developer."]], required: []),
        Tool(name: "close_tile",
             description: "Close a tile the way the developer would (it can be brought back from Undo or recently closed). Idle shells and idle agents close at once; a working, asking, starting or busy tile is refused unless force asks the developer to approve. The overseer's own tile is never closed, and an ask: card is dismissed.",
             properties: ["tile": ["type": "string", "description": "Tile id or exact title (from board)."],
                          "force": ["type": "boolean", "description": "When the tile is busy, ask the developer to approve closing it instead of refusing."]],
             required: ["tile"]),
        Tool(name: "open_tile",
             description: "Start a tile the way the developer would: a shell or one of the installed agents (claude, codex, devin, omp — refuse otherwise). cwd is required and must be an existing directory. prompt (agents only) is delivered to the tile like send_to_tile once it sits idle. resume (agents only) opens a known conversation by its session id, once. reopen brings back a tile id from board's Recently closed list, and takes no other parameters. Each caller may open a limited number of tiles per hour. Returns the tile id and, once reported, its Accord address.",
             properties: ["agent": ["type": "string", "description": "shell, claude, codex, devin or omp."],
                          "cwd": ["type": "string", "description": "Working directory (~ allowed); must exist."],
                          "title": ["type": "string", "description": "The tile's title."],
                          "prompt": ["type": "string", "description": "A first message, delivered at the agent's idle prompt."],
                          "resume": ["type": "string", "description": "Session id of the conversation to resume."],
                          "reopen": ["type": "string", "description": "A closed tile's id, from board's Recently closed list."]],
             required: []),
        Tool(name: "read_tile",
             description: "What a tile shows now: a terminal's screen, a conversation's latest messages, a job's notes. Credentials are removed.",
             properties: ["tile": ["type": "string", "description": "Tile id or exact title (from board)."],
                          "lines": ["type": "integer", "description": "How many lines or messages, default 60."]],
             required: ["tile"]),
        Tool(name: "send_to_tile",
             description: "Send a message to a tile, typed at its prompt once the agent is idle (a native-prompt delivery). accord_send with delivery \"native-prompt\" to the tile's Accord address does the same.",
             properties: ["tile": ["type": "string", "description": "Tile id or exact title (from board)."],
                          "text": ["type": "string", "description": "The message, at most 4000 characters."]],
             required: ["tile", "text"]),
        Tool(name: "whoami",
             description: "Which tile you are, as far as Tessera can tell (from TESSERA_TILE_ID or your working folder).",
             properties: [:], required: [])
    ]
}
