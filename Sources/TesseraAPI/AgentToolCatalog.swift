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
        enrollment is needed. These tools inspect Tessera's visible board and native terminal screens.
        """

    public static let tools: [Tool] = [
        Tool(name: "board",
             description: "Everything on the board: each tile's id, title, kind, state and a one-line summary, plus the steward's brief of what needs the developer. Use Accord to discover collaborators across hosts.",
             properties: ["waiting_only": ["type": "boolean", "description": "Only tiles waiting on the developer."]], required: []),
        Tool(name: "read_tile",
             description: "What a tile shows now: a terminal's screen, a conversation's latest messages, a job's notes. Credentials are removed.",
             properties: ["tile": ["type": "string", "description": "Tile id or exact title (from board)."],
                          "lines": ["type": "integer", "description": "How many lines or messages, default 60."]],
             required: ["tile"]),
        Tool(name: "whoami",
             description: "Which tile you are, as far as Tessera can tell (from TESSERA_TILE_ID or your working folder).",
             properties: [:], required: [])
    ]
}
