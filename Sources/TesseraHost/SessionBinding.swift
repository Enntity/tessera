import Foundation
import TesseraKit

/// Matches terminal tiles running an agent with no known conversation id (Codex, or anything typed
/// into a shell or started through a launcher) to the session file their tool wrote: same folder,
/// begun just after the agent started, not already another tile's. Earliest launch picks first.
enum SessionBinding {
    struct Candidate: Sendable {
        let tileId: String
        let cwd: String
        let launchedAt: Date
        /// The command continues an existing conversation (`resume --last`, `--continue`), so its
        /// session file predates the launch; match on being written after it instead.
        var continuing = false
    }

    /// Two agents started in the same folder within a minute can't be told apart by folder and
    /// time; binding the wrong one would resume someone else's conversation, so neither is bound
    /// (they resume fresh) rather than guess.
    static func unambiguous(_ candidates: [Candidate]) -> [Candidate] {
        candidates.filter { c in
            !candidates.contains { $0.tileId != c.tileId && $0.cwd == c.cwd && abs($0.launchedAt.timeIntervalSince(c.launchedAt)) < 60 }
        }
    }

    /// Runs the shared loop; each tool supplies `match`: the session id for a candidate, given its
    /// standardized folder, the earliest time its file may date from, and the ids already taken.
    static func assign(_ candidates: [Candidate], claimed: Set<String>,
                       match: (_ candidate: Candidate, _ folder: String, _ since: Date, _ taken: Set<String>) -> String?) -> [String: String] {
        var taken = claimed
        var result: [String: String] = [:]
        for c in candidates.sorted(by: { $0.launchedAt < $1.launchedAt }) {
            // The tool may create its file a moment before the tile noted the launch.
            guard let id = match(c, c.cwd.standardizedPath, c.launchedAt.addingTimeInterval(-3), taken) else { continue }
            result[c.tileId] = id
            taken.insert(id)
        }
        return result
    }
}
