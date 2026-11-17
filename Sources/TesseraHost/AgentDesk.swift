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
        /// The sender shown to the user (a tile's title, or the Accord address when unknown).
        public var from: String
        /// The sender's Accord address, when it has one (nil for a local send on this board).
        public var fromAddress: String?
        public var fromTile: String?
        public var to: String
        public var toTitle: String
        public var text: String
        public var sentAt: Date
        public var read: Bool = false
        /// waiting or open (cards for the user), queued (types when the tile is idle), attempting,
        /// typed, opened, failed, declined, reviewed, or nil (inbox only).
        public var delivery: String?
    }

    /// What becomes of a message meant for a tile's prompt, decided by the caller: it stays in
    /// Accord (`.inbox`), is typed once the tile sits idle at its prompt (`.queued`), waits for
    /// the user's OK first (`.ask`), or is offered to open in a desktop app with the text on the
    /// pasteboard (`.open`).
    public enum Route: Equatable {
        case inbox, queued, ask, open
    }

    public struct Note: Codable, Equatable, Sendable {
        public var id: String
        public var from: String
        public var text: String
        public var at: Date
    }

    /// An agent's request to close a busy tile, waiting on the developer's card.
    public struct CloseRequest: Codable, Equatable, Sendable {
        public var id: String        // "close:" + UUID
        public var from: String
        public var fromTile: String?
        public var tile: String
        public var title: String
        public var reason: String
        public var at: Date
    }

    private struct Saved: Codable {
        var questions: [Question]
        var messages: [Message]
        var notes: [Note]
        var accordDeliveries: [String]?
        var noteReads: [String]?
        var noWake: [String]?
        var closeRequests: [CloseRequest]?
    }

    public private(set) var questions: [Question] = []
    public private(set) var messages: [Message] = []
    public private(set) var notes: [Note] = []
    /// Close requests still waiting for the developer; answered ones leave the list.
    public private(set) var closeRequests: [CloseRequest] = []
    /// Called when what the board shows from the desk may have changed.
    @ObservationIgnored public var onChange: (() -> Void)?
    /// Types a message into a terminal tile; false when it can't (not a running terminal).
    @ObservationIgnored public var typeInto: ((String, String) -> Bool)?
    /// Opens an app conversation with the message's text already on the pasteboard; false when it can't.
    @ObservationIgnored public var openWithText: ((String, String) -> Bool)?
    /// The developer answered a close request; Workspace does the actual close (or logs the decline).
    @ObservationIgnored public var closeApproved: ((CloseRequest) -> Void)?
    @ObservationIgnored public var closeDeclined: ((CloseRequest) -> Void)?
    /// Who may have a message typed without the user approving each one (Settings → Agents).
    public var wakePolicy = WakePolicy.stored {
        didSet { wakePolicy.save() }
    }
    /// Tiles the user has kept from being woken without asking, however the policy reads.
    public private(set) var noWake: Set<String> = []

    public static let idPrefix = "ask:"
    static let keep: TimeInterval = 24 * 3600

    @ObservationIgnored private let store: URL

    /// Delivery ids already taken, Accord's and local ones alike.
    private var deliveries: Set<String> = []
    private var noteReads: Set<String> = []

    public init(directory: URL) {
        store = directory.appendingPathComponent("accord-desk.json")
        if let saved = StateFile.load(Saved.self, from: store) {
            (questions, messages, notes) = (saved.questions, saved.messages, saved.notes)
            deliveries = Set(saved.accordDeliveries ?? [])
            noteReads = Set(saved.noteReads ?? [])
            noWake = Set(saved.noWake ?? [])
            closeRequests = saved.closeRequests ?? []
        }
    }

    /// Tiles the user has kept from being woken without asking, however the policy reads.
    public func setNoWake(_ id: String, _ off: Bool) {
        if off { noWake.insert(id) } else { noWake.remove(id) }
        changed()
    }

    // MARK: Questions

    public func question(_ id: String) -> Question? { questions.first { $0.id == id } }

    public func answer(_ id: String, with answer: String) {
        guard let i = questions.firstIndex(where: { $0.id == id }), questions[i].answer == nil else { return }
        questions[i].answer = answer.preview(4000)
        questions[i].answeredAt = Date()
        changed()
    }

    /// One message headed for a tile — an Accord delivery (`id` "accord:…") or a local send
    /// ("local:…"). Delivery IDs are durable deduplication keys, including across app restart.
    /// Persisted before any native interaction so a crash cannot cause retyping.
    public func importMessage(id: String, text: String, from label: String, address: String?, tile fromTile: String?,
                              to: String, title: String, route: Route, at: Date = Date()) -> Bool {
        if deliveries.contains(id) { return true }
        // Ordinary inbox content stays exclusively in Accord.
        guard route != .inbox else { return true }
        deliveries.insert(id)
        var message = Message(id: id, from: label, fromAddress: address, fromTile: fromTile, to: to, toTitle: title,
                              text: Redactor.redact(text).preview(4000), sentAt: at)
        switch route {
        case .queued: message.delivery = "queued"
        case .ask: message.delivery = "waiting"
        case .open: message.delivery = "open"
        case .inbox: break
        }
        messages.append(message); changed()
        guard let saved = StateFile.load(Saved.self, from: store), saved.accordDeliveries?.contains(id) == true else {
            deliveries.remove(id)
            messages.removeAll { $0.id == id }
            return false
        }
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

    /// The user's answer to a waiting card: "Deliver" queues it for when the tile sits idle at its
    /// prompt; "Open and Copy" puts the text on the pasteboard and opens the conversation in its app.
    public func approveDelivery(_ id: String, _ approve: Bool) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        switch messages[i].delivery {
        case "waiting":
            messages[i].delivery = approve ? "queued" : "declined"
        case "open":
            messages[i].delivery = approve && openWithText?(messages[i].to, Self.typed(messages[i])) == true ? "opened" : (approve ? "failed" : "declined")
        default:
            return
        }
        changed()
    }

    /// The tiles with messages queued for typing, in the order their first one arrived.
    public var queuedTiles: [String] {
        var seen: Set<String> = []
        return messages.filter { $0.delivery == "queued" }.compactMap { seen.insert($0.to).inserted ? $0.to : nil }
    }

    /// The next queued message for a tile that can take it now: persisted as "attempting" before
    /// the terminal is touched — after a crash it stays unknown and is never replayed — then typed
    /// through `typeInto`. False when nothing is queued, or when the attempt never reached the
    /// terminal (a failed persist leaves the message at "attempting" and never retried).
    @discardableResult
    public func deliverQueued(_ tile: String) -> Bool {
        guard let first = messages.first(where: { $0.delivery == "queued" && $0.to == tile }) else { return false }
        let id = first.id
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return false }
        messages[i].delivery = "attempting"
        changed()
        guard let saved = StateFile.load(Saved.self, from: store),
              saved.messages.first(where: { $0.id == id })?.delivery == "attempting",
              let j = messages.firstIndex(where: { $0.id == id }) else { return false }
        messages[j].delivery = typeInto?(tile, Self.typed(messages[j])) == true ? "typed" : "failed"
        changed()
        return true
    }

    /// A queued message that has waited past `keep` fails rather than type a day late.
    public func expireQueued(now: Date = Date()) {
        var touched = false
        for i in messages.indices where messages[i].delivery == "queued" && now.timeIntervalSince(messages[i].sentAt) > Self.keep {
            messages[i].delivery = "failed"
            touched = true
        }
        if touched { changed() }
    }

    /// A queued message whose tile is gone for good fails, so the user is told to check it.
    public func failQueued(_ tile: String) {
        var touched = false
        for i in messages.indices where messages[i].delivery == "queued" && messages[i].to == tile {
            messages[i].delivery = "failed"
            touched = true
        }
        if touched { changed() }
    }

    /// What the tile's card shows of the latest message headed for it: pending ones while they
    /// last; a delivered, opened or failed one for an hour after.
    public func wakeMark(for tile: String, now: Date = Date()) -> WakeMark? {
        guard let m = messages.filter({ $0.to == tile }).max(by: { $0.sentAt < $1.sentAt }) else { return nil }
        let state: WakeMark.State
        switch m.delivery {
        case "queued", "attempting": state = .queued
        case "waiting": state = .waiting
        case "open": state = .waiting
        case "typed": state = .typed
        case "opened": state = .open
        case "failed": state = .failed
        default: return nil
        }
        if [.typed, .open, .failed].contains(state), now.timeIntervalSince(m.sentAt) > 3600 { return nil }
        return WakeMark(from: m.from, text: m.text, state: state, at: m.sentAt)
    }

    /// What is typed into the tile: who sent it, how to answer, and — for an Accord delivery —
    /// how to acknowledge it once handled.
    static func typed(_ message: Message) -> String {
        guard message.id.hasPrefix("accord:") else {
            return "[Message from \(message.from) via Tessera] \(message.text)"
        }
        let reply = message.fromAddress.map { "; reply with accord_send to \($0)" } ?? ""
        return "[Message from \(message.from) via Accord\(reply); accord_read \(message.id.dropFirst(7)) once handled] \(message.text)"
    }

    // MARK: The board

    /// The user dealt with a desk tile without answering it (Mark as Seen, Dismiss, Hide): a
    /// question is set aside, a delivery declined, a note gone.
    public func setAside(_ tileId: String) {
        guard tileId.hasPrefix(Self.idPrefix) else { return }
        let id = String(tileId.dropFirst(Self.idPrefix.count))
        if let i = questions.firstIndex(where: { $0.id == id && $0.answer == nil }) { questions[i].dismissed = true }
        if messages.contains(where: { $0.id == id && ["waiting", "open"].contains($0.delivery ?? "") }) { approveDelivery(id, false) }
        if id.hasPrefix("accord:"), notes.contains(where: { $0.id == id }) { noteReads.insert(String(id.dropFirst(7))) }
        notes.removeAll { $0.id == id }
        if let i = messages.firstIndex(where:{ $0.id == id && ["attempting","failed"].contains($0.delivery ?? "") }) { messages[i].delivery = "reviewed" }
        if let i = closeRequests.firstIndex(where: { $0.id == id }) {
            closeDeclined?(closeRequests.remove(at: i))
        }
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
        for m in messages where m.delivery == "open" {
            out.append(tile(id: m.id, title: "\(m.from) → \(m.toTitle)", activity: .needsInput,
                            detail: "Open \(m.toTitle) with this on the pasteboard? \(m.text)", at: m.sentAt,
                            items: [ConversationItem(id: m.id, role: .assistant, text: m.text, timestamp: m.sentAt)], link: m.to))
        }
        for r in closeRequests {
            let detail = "Close \(r.title)? It's \(r.reason)."
            out.append(tile(id: r.id, title: "\(r.from) asks to close \(r.title)", activity: .needsInput,
                            detail: detail, at: r.at,
                            items: [ConversationItem(id: r.id, role: .assistant, text: detail, timestamp: r.at)], link: r.tile))
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
        if messages.contains(where: { $0.id == id && $0.delivery == "open" }) { return ["Open and Copy", "Dismiss"] }
        if closeRequests.contains(where: { $0.id == id }) { return ["Close", "Don't"] }
        return nil
    }

    /// Whether the desk tile takes a free-text reply: only a pending question does — choice
    /// cards (Deliver, Open and Copy, Close) are answered by their buttons.
    public func takesReply(_ tileId: String) -> Bool {
        let id = String(tileId.dropFirst(Self.idPrefix.count))
        return questions.contains { $0.id == id && $0.answer == nil && !$0.dismissed }
    }

    /// An answer given from the lane: a question's answer, or a delivery decision.
    public func respond(_ tileId: String, with answer: String) {
        let id = String(tileId.dropFirst(Self.idPrefix.count))
        if messages.contains(where: { $0.id == id && ["waiting", "open"].contains($0.delivery ?? "") }) {
            approveDelivery(id, answer == "Deliver" || answer == "Open and Copy")
        } else if let i = closeRequests.firstIndex(where: { $0.id == id }) {
            let request = closeRequests.remove(at: i)
            changed()
            if answer == "Close" { closeApproved?(request) } else { closeDeclined?(request) }
        } else {
            self.answer(id, with: answer)
        }
    }

    /// A close request for a busy tile: one card per tile — a second request for the same
    /// tile returns the pending one.
    @discardableResult
    public func requestClose(from: String, fromTile: String?, tile: String, title: String, reason: String,
                             at: Date = Date()) -> CloseRequest {
        if let existing = closeRequests.first(where: { $0.tile == tile }) { return existing }
        let request = CloseRequest(id: "close:" + UUID().uuidString, from: from, fromTile: fromTile,
                                   tile: tile, title: title, reason: reason, at: at)
        closeRequests.append(request)
        changed()
        return request
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
        // Done-with messages of any origin age out; anything still undelivered keeps its place.
        messages.removeAll { $0.sentAt < cutoff && ["typed", "opened", "declined", "reviewed"].contains($0.delivery ?? "") }
        // A close OK this stale must not linger.
        closeRequests.removeAll { $0.at < cutoff }
        StateFile.save(Saved(questions: questions, messages: messages, notes: notes, accordDeliveries: Array(deliveries),
                             noteReads: Array(noteReads), noWake: Array(noWake), closeRequests: closeRequests), to: store)
        onChange?()
    }

}
