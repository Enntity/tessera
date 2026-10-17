import Foundation
import Observation
import TesseraKit

/// What agents on this Mac leave for the user and for each other through Tessera: questions for
/// the user (answered from the Needs-you lane), notes for the user, and messages between agents
/// (kept in the recipient's inbox, and typed into a terminal agent when the user allows it or
/// approves the delivery). Each item that wants the user is a tile, so it joins the lane, alerts and
/// the phone like everything else.
@Observable
@MainActor
public final class AgentDesk {
    public struct Question: Codable, Equatable, Sendable {
        public var id: String
        public var from: String
        public var fromTile: String?
        public var text: String
        public var options: [String]
        public var askedAt: Date
        public var answer: String?
        public var answeredAt: Date?
        /// The user set it aside without answering.
        public var dismissed: Bool = false
    }

    public struct Message: Codable, Equatable, Sendable {
        public var id: String
        public var from: String
        public var fromTile: String?
        public var to: String
        public var toTitle: String
        public var text: String
        public var sentAt: Date
        public var read: Bool = false
        /// waiting (for the user to approve typing it in), typed, declined, or nil (inbox only).
        public var delivery: String?
    }

    public struct Note: Codable, Equatable, Sendable {
        public var id: String
        public var from: String
        public var text: String
        public var at: Date
    }

    private struct Saved: Codable {
        var questions: [Question]
        var messages: [Message]
        var notes: [Note]
    }

    public private(set) var questions: [Question] = []
    public private(set) var messages: [Message] = []
    public private(set) var notes: [Note] = []
    /// Called when what the board shows from the desk may have changed.
    @ObservationIgnored public var onChange: (() -> Void)?
    /// Types a message into a terminal tile; false when it can't (not a running terminal).
    @ObservationIgnored public var typeInto: ((String, String) -> Bool)?
    /// Agents may type messages straight into terminal agents; otherwise the user approves each one.
    public var typingAllowed = Preferences.store.bool(forKey: "tessera.agentsMayType") {
        didSet { Preferences.store.set(typingAllowed, forKey: "tessera.agentsMayType") }
    }

    public static let idPrefix = "ask:"
    static let keep: TimeInterval = 24 * 3600
    static let limit = 200

    @ObservationIgnored private let store: URL

    public init(directory: URL) {
        store = directory.appendingPathComponent("agent-desk.json")
        if let saved = StateFile.load(Saved.self, from: store) {
            (questions, messages, notes) = (saved.questions, saved.messages, saved.notes)
        }
    }

    // MARK: Questions

    @discardableResult
    public func ask(_ text: String, options: [String], from: String, fromTile: String?) -> Question {
        let question = Question(id: Self.newId(), from: from, fromTile: fromTile, text: text.preview(2000),
                                options: options.prefix(6).map { $0.preview(60) }, askedAt: Date())
        questions.append(question)
        changed()
        return question
    }

    public func question(_ id: String) -> Question? { questions.first { $0.id == id } }

    public func answer(_ id: String, with answer: String) {
        guard let i = questions.firstIndex(where: { $0.id == id }), questions[i].answer == nil else { return }
        questions[i].answer = answer.preview(4000)
        questions[i].answeredAt = Date()
        changed()
    }

    // MARK: Messages

    /// Leaves `text` in the inbox of tile `to`, and for a terminal agent types it in too, now or
    /// once the user approves (`typingAllowed`).
    public func send(_ text: String, from: String, fromTile: String?, to: String, toTitle: String, type: Bool) -> Message {
        var message = Message(id: Self.newId(), from: from, fromTile: fromTile, to: to, toTitle: toTitle,
                              text: text.preview(4000), sentAt: Date())
        if type {
            if typingAllowed {
                message.delivery = typeInto?(to, Self.typed(message)) == true ? "typed" : nil
            } else {
                message.delivery = "waiting"
            }
        }
        messages.append(message)
        changed()
        return message
    }

    /// The messages for `tile`, oldest first; reading them marks them read.
    public func inbox(for tile: String, unreadOnly: Bool, markRead: Bool) -> [Message] {
        let found = messages.filter { $0.to == tile && (!unreadOnly || !$0.read) }
        if markRead, found.contains(where: { !$0.read }) {
            for i in messages.indices where messages[i].to == tile { messages[i].read = true }
            changed()
        }
        return found
    }

    public func approveDelivery(_ id: String, _ approve: Bool) {
        guard let i = messages.firstIndex(where: { $0.id == id }), messages[i].delivery == "waiting" else { return }
        messages[i].delivery = approve ? (typeInto?(messages[i].to, Self.typed(messages[i])) == true ? "typed" : "failed") : "declined"
        changed()
    }

    static func typed(_ message: Message) -> String {
        "[Message from \(message.from) via Tessera] \(message.text)"
    }

    // MARK: Notes

    public func note(_ text: String, from: String) {
        notes.append(Note(id: Self.newId(), from: from, text: text.preview(1000), at: Date()))
        changed()
    }

    // MARK: The board

    /// The user dealt with a desk tile without answering it (Mark as Seen, Dismiss, Hide): a
    /// question is set aside, a delivery declined, a note gone.
    public func setAside(_ tileId: String) {
        guard tileId.hasPrefix(Self.idPrefix) else { return }
        let id = String(tileId.dropFirst(Self.idPrefix.count))
        if let i = questions.firstIndex(where: { $0.id == id && $0.answer == nil }) { questions[i].dismissed = true }
        if messages.contains(where: { $0.id == id && $0.delivery == "waiting" }) { approveDelivery(id, false) }
        notes.removeAll { $0.id == id }
        changed()
    }

    /// A note the user has now seen goes.
    public func seen(_ tileId: String) {
        let id = String(tileId.dropFirst(Self.idPrefix.count))
        guard tileId.hasPrefix(Self.idPrefix), notes.contains(where: { $0.id == id }) else { return }
        notes.removeAll { $0.id == id }
        changed()
    }

    /// The desk's tiles: open questions, deliveries waiting for approval, and notes.
    public var sessions: [AgentAppSession] {
        var out: [AgentAppSession] = []
        for q in questions where q.answer == nil && !q.dismissed {
            out.append(tile(id: q.id, title: "\(q.from) asks", activity: .needsInput, detail: q.text, at: q.askedAt,
                            items: [ConversationItem(id: q.id, role: .assistant, text: q.text, timestamp: q.askedAt)], link: q.fromTile))
        }
        for m in messages where m.delivery == "waiting" {
            out.append(tile(id: m.id, title: "\(m.from) → \(m.toTitle)", activity: .needsInput,
                            detail: "Type this into \(m.toTitle)? \(m.text)", at: m.sentAt,
                            items: [ConversationItem(id: m.id, role: .assistant, text: m.text, timestamp: m.sentAt)], link: m.to))
        }
        for n in notes {
            out.append(tile(id: n.id, title: "From \(n.from)", activity: .done, detail: n.text, at: n.at,
                            items: [ConversationItem(id: n.id, role: .assistant, text: n.text, timestamp: n.at)], link: nil))
        }
        return out
    }

    /// The options a desk tile offers in the lane: a question's, or Deliver / Don't for a message.
    public func choices(for tileId: String) -> [String]? {
        let id = String(tileId.dropFirst(Self.idPrefix.count))
        if let q = questions.first(where: { $0.id == id && $0.answer == nil }) { return q.options }
        if messages.contains(where: { $0.id == id && $0.delivery == "waiting" }) { return ["Deliver", "Don't"] }
        return nil
    }

    /// An answer given from the lane: a question's answer, or a delivery decision.
    public func respond(_ tileId: String, with answer: String) {
        let id = String(tileId.dropFirst(Self.idPrefix.count))
        if messages.contains(where: { $0.id == id && $0.delivery == "waiting" }) {
            approveDelivery(id, answer == "Deliver")
        } else {
            self.answer(id, with: answer)
        }
    }

    private func tile(id: String, title: String, activity: TileActivity, detail: String, at: Date,
                      items: [ConversationItem], link: String?) -> AgentAppSession {
        AgentAppSession(id: Self.idPrefix + id, flavor: .agentDesk, title: title, cwd: "via Tessera", openURL: nil, resumeCommand: nil,
                        snapshot: ConversationSnapshot(items: items, activity: activity, detail: detail, lastEventAt: at),
                        summary: nil, lastActivityAt: at, link: link)
    }

    private func changed() {
        let cutoff = Date().addingTimeInterval(-Self.keep)
        questions.removeAll { ($0.answeredAt ?? ($0.dismissed ? $0.askedAt : .distantFuture)) < cutoff }
        messages.removeAll { $0.sentAt < cutoff && $0.read && $0.delivery != "waiting" }
        if questions.count > Self.limit { questions.removeFirst(questions.count - Self.limit) }
        if messages.count > Self.limit { messages.removeFirst(messages.count - Self.limit) }
        if notes.count > Self.limit { notes.removeFirst(notes.count - Self.limit) }
        StateFile.save(Saved(questions: questions, messages: messages, notes: notes), to: store)
        onChange?()
    }

    static func newId() -> String { String(UUID().uuidString.prefix(8)).lowercased() }
}
