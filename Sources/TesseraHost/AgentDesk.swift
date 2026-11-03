import Foundation
import Observation
import TesseraKit

/// Native presentation of Accord questions and operator notifications, plus durable
/// receipts for terminal input. This is not an agent mailbox or session authority.
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
        var accordDeliveries: [String]?
        var noteReads: [String]?
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

    @ObservationIgnored private let store: URL

    private var accordDeliveries: Set<String> = []
    private var noteReads: Set<String> = []

    public init(directory: URL) {
        store = directory.appendingPathComponent("accord-desk.json")
        if let saved = StateFile.load(Saved.self, from: store) {
            (questions, messages, notes) = (saved.questions, saved.messages, saved.notes)
            accordDeliveries = Set(saved.accordDeliveries ?? [])
            noteReads = Set(saved.noteReads ?? [])

        }
    }

    // MARK: Questions

    public func question(_ id: String) -> Question? { questions.first { $0.id == id } }

    public func answer(_ id: String, with answer: String) {
        guard let i = questions.firstIndex(where: { $0.id == id }), questions[i].answer == nil else { return }
        questions[i].answer = answer.preview(4000)
        questions[i].answeredAt = Date()
        changed()
    }

    /// Accord delivery IDs are durable deduplication keys, including across app restart.
    public func importAccordMessage(id: String, text: String, from: String, to: String, title: String, wantsTyping: Bool) -> Bool {
        let key = "accord:" + id
        if accordDeliveries.contains(key) { return true }
        guard wantsTyping else { return true } // Ordinary inbox content stays exclusively in Accord.
        accordDeliveries.insert(key)
        var message = Message(id: key, from: from, fromTile: nil, to: to, toTitle: title, text: Redactor.redact(text).preview(4000), sentAt: Date())
        // Persist the delivery before optional native interaction. A crash cannot cause retyping.
        if wantsTyping { message.delivery = "waiting" }
        messages.append(message); changed()
        guard let saved = StateFile.load(Saved.self, from: store), saved.accordDeliveries?.contains(key) == true else {
            accordDeliveries.remove(key)
            messages.removeAll { $0.id == key }
            return false
        }
        if wantsTyping && typingAllowed { approveDelivery(key, true) }
        return true
    }
    public func importAccordQuestions(_ values: [[String: Any]]) {
        let pending = Set(values.compactMap { $0["id"] as? String }.map { "accord:" + $0 })
        let before = questions.count
        questions.removeAll { $0.id.hasPrefix("accord:") && $0.answer == nil && !$0.dismissed && !pending.contains($0.id) }
        if questions.count != before { changed() }
        for value in values {
            guard let id = value["id"] as? String, let text = value["question"] as? String,
                  !questions.contains(where: { $0.id == "accord:" + id }) else { continue }
            let options: [String]
            if let raw = value["options"] as? String, let data = raw.data(using: .utf8) {
                options = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            } else { options = value["options"] as? [String] ?? [] }
            questions.append(Question(id: "accord:" + id, from: "Accord", fromTile: nil, text: Redactor.redact(text), options: options, askedAt: Date()))
            changed()
        }
    }
    public func accordAnswers() -> [(String, String)] {
        questions.compactMap { question in
            guard question.id.hasPrefix("accord:") else { return nil }
            if question.dismissed { return (String(question.id.dropFirst(7)), "__accord_dismissed__") }
            guard let answer = question.answer else { return nil }
            return (String(question.id.dropFirst(7)), answer)
        }
    }

    public func importAccordNotes(_ values: [[String: Any]]) {
        let pending = Set(values.compactMap { $0["deliveryId"] as? String }.map { "accord:" + $0 })
        notes.removeAll { $0.id.hasPrefix("accord:") && !pending.contains($0.id) }
        for value in values {
            guard let id = value["deliveryId"] as? String, let text = value["text"] as? String,
                  !noteReads.contains(id), !notes.contains(where: { $0.id == "accord:" + id }) else { continue }
            notes.append(Note(id:"accord:" + id, from:value["from"] as? String ?? "Accord", text:Redactor.redact(text), at:Date()))
        }
        changed()
    }
    public func accordNoteReads() -> [String] { Array(noteReads) }
    public func confirmNoteRead(_ id: String) { noteReads.remove(id); changed() }

    // MARK: Messages

    public func approveDelivery(_ id: String, _ approve: Bool) {
        guard id.hasPrefix("accord:"), let i = messages.firstIndex(where: { $0.id == id }), messages[i].delivery == "waiting" else { return }
        if !approve { messages[i].delivery = "declined"; changed(); return }
        // Record intent before the irreversible terminal effect. After a crash this remains
        // unknown and is never automatically replayed; displaying a message is not execution.
        messages[i].delivery = "attempting"
        changed()
        guard let saved = StateFile.load(Saved.self, from: store),
              saved.messages.first(where: { $0.id == id })?.delivery == "attempting" else { return }
        messages[i].delivery = typeInto?(messages[i].to, Self.typed(messages[i])) == true ? "typed" : "failed"
        changed()
    }

    static func typed(_ message: Message) -> String {
        "[Message from \(message.from) via Accord] \(message.text)"
    }

    // MARK: The board

    /// The user dealt with a desk tile without answering it (Mark as Seen, Dismiss, Hide): a
    /// question is set aside, a delivery declined, a note gone.
    public func setAside(_ tileId: String) {
        guard tileId.hasPrefix(Self.idPrefix) else { return }
        let id = String(tileId.dropFirst(Self.idPrefix.count))
        if let i = questions.firstIndex(where: { $0.id == id && $0.answer == nil }) { questions[i].dismissed = true }
        if messages.contains(where: { $0.id == id && $0.delivery == "waiting" }) { approveDelivery(id, false) }
        if id.hasPrefix("accord:"), notes.contains(where: { $0.id == id }) { noteReads.insert(String(id.dropFirst(7))) }
        notes.removeAll { $0.id == id }
        if let i = messages.firstIndex(where:{ $0.id == id && ["attempting","failed"].contains($0.delivery ?? "") }) { messages[i].delivery = "reviewed" }
        changed()
    }

    /// A note the user has now seen goes.
    public func seen(_ tileId: String) {
        let id = String(tileId.dropFirst(Self.idPrefix.count))
        guard tileId.hasPrefix(Self.idPrefix), notes.contains(where: { $0.id == id }) else { return }
        if id.hasPrefix("accord:"), notes.contains(where: { $0.id == id }) { noteReads.insert(String(id.dropFirst(7))) }
        notes.removeAll { $0.id == id }
        if let i = messages.firstIndex(where:{ $0.id == id && ["attempting","failed"].contains($0.delivery ?? "") }) { messages[i].delivery = "reviewed" }
        changed()
    }

    /// The desk's tiles: open questions, deliveries waiting for approval, and notes.
    public var sessions: [AgentAppSession] {
        var out: [AgentAppSession] = []
        for q in questions where q.answer == nil && !q.dismissed {
            out.append(tile(id: q.id, title: "\(q.from) asks", activity: .needsInput, detail: q.text, at: q.askedAt,
                            items: [ConversationItem(id: q.id, role: .assistant, text: q.text, timestamp: q.askedAt)], link: q.fromTile))
        }
        for m in messages where m.delivery == "attempting" || m.delivery == "failed" {
            let detail = m.delivery == "attempting" ? "Terminal delivery outcome is unknown after interruption. Check the terminal before sending again." : "Terminal delivery failed. Check the terminal before sending again."
            out.append(tile(id:m.id,title:"Check delivery to \(m.toTitle)",activity:.needsInput,detail:detail,at:m.sentAt,
                items:[ConversationItem(id:m.id,role:.system,text:detail + "\n" + m.text,timestamp:m.sentAt)],link:m.to))
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
        if id.hasPrefix("accord:"), messages.contains(where: { $0.id == id && $0.delivery == "waiting" }) { return ["Deliver", "Don't"] }
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
        questions.removeAll { $0.id.hasPrefix("accord:") && ($0.answeredAt ?? ($0.dismissed ? $0.askedAt : .distantFuture)) < cutoff }
        messages.removeAll { $0.id.hasPrefix("accord:") && $0.sentAt < cutoff && $0.read && $0.delivery != "waiting" }
        StateFile.save(Saved(questions: questions, messages: messages, notes: notes, accordDeliveries: Array(accordDeliveries), noteReads: Array(noteReads)), to: store)
        onChange?()
    }

}
