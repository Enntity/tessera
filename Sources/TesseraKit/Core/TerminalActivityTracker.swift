import Foundation

/// Infers a terminal's state from output timing, bells, OSC notifications and the visible screen.
///
/// Agent CLIs animate a spinner while they work and go quiet when they finish or block, so
/// "sustained output → silence" is a strong completion signal. Prompts that need a decision are
/// recognised from the text on screen once output has settled.
public struct TerminalActivityTracker: Sendable {
    public private(set) var activity: TileActivity = .starting
    public private(set) var attention = false
    public private(set) var detail: String?

    /// While the user is looking at a tile, nothing it does counts as unseen.
    public var isBeingViewed = false

    private var lastOutputAt: Date?
    private var startedAt: Date?
    private var burstStartedAt: Date?
    private var lastInputAt: Date?
    private var exited = false
    /// The prompt the user last responded to; it can linger on screen but is no longer a question.
    private var answeredPrompt: String?
    private var visiblePrompt: String?

    /// Output this long after a keystroke is treated as echo, not work.
    static let echoWindow: TimeInterval = 0.35
    /// Output within this window means the program is actively producing.
    static let workingWindow: TimeInterval = 1.2
    /// A burst must last this long to count as a finished task when it stops.
    static let meaningfulBurst: TimeInterval = 2.0
    /// Quiet needed before we trust what is on screen.
    static let settleTime: TimeInterval = 0.8

    public init() {}

    public mutating func noteInput(at now: Date) {
        lastInputAt = now
        if let visiblePrompt { answeredPrompt = visiblePrompt }
        if activity == .needsInput {
            activity = .idle
            detail = nil
            attention = false
        }
    }

    public mutating func noteOutput(bytes: Int, at now: Date) {
        guard bytes > 0, !exited else { return }
        if let input = lastInputAt, now.timeIntervalSince(input) < Self.echoWindow, bytes < 256 {
            lastOutputAt = lastOutputAt ?? now
            return
        }
        if let last = lastOutputAt, now.timeIntervalSince(last) < Self.workingWindow, burstStartedAt != nil {
            // Burst continues.
        } else {
            burstStartedAt = now
        }
        lastOutputAt = now
    }

    public mutating func noteBell(screenTail: [String], at now: Date) {
        let prompt = openPrompt(in: Array(screenTail.suffix(14)))
        raise(needsInput: prompt != nil, detail: prompt)
    }

    public mutating func noteNotification(title: String, body: String) {
        let text = [title, body].filter { !$0.isEmpty }.joined(separator: " — ")
        let asksForInput = Self.matchesPrompt(text.lowercased())
        raise(needsInput: asksForInput, detail: text.isEmpty ? nil : text.preview(120))
    }

    /// The program ended with `code`, or never started at all (`failure` says why).
    public mutating func noteExit(code: Int32?, failure: String? = nil) {
        exited = true
        activity = (code ?? 0) == 0 && failure == nil ? .exited : .failed
        detail = failure ?? code.map { "Exited with status \($0)" } ?? "Exited"
        if activity == .failed, !isBeingViewed { attention = true }
    }

    /// Deliberately stopped: quiet, no attention, and a note on how it comes back.
    public mutating func noteSuspended(resumeHint: String) {
        exited = true
        activity = .exited
        attention = false
        detail = resumeHint
    }

    public mutating func restart() {
        self = TerminalActivityTracker()
    }

    /// The user opened the tile: clear the unseen marker and settle finished work to idle.
    public mutating func acknowledge() {
        attention = false
        if activity == .done { activity = .idle }
    }

    /// Re-evaluate from timing and the bottom of the screen. Returns true when anything visible changed.
    @discardableResult
    public mutating func tick(now: Date, screenTail: [String]) -> Bool {
        guard !exited else { return false }
        if startedAt == nil { startedAt = now }
        let before = (activity, attention, detail)

        let quietFor = lastOutputAt.map { now.timeIntervalSince($0) } ?? .infinity
        let tail = screenTail.suffix(24)
        let spinnerVisible = tail.contains { $0.range(of: "esc to interrupt", options: .caseInsensitive) != nil }

        if quietFor < Self.workingWindow || spinnerVisible {
            if activity != .working { detail = nil }
            activity = .working
        } else if quietFor >= Self.settleTime, let prompt = openPrompt(in: Array(tail.suffix(14))) {
            if activity != .needsInput { raise(needsInput: true, detail: prompt) }
        } else if activity == .working {
            let burst = (lastOutputAt ?? now).timeIntervalSince(burstStartedAt ?? now)
            burstStartedAt = nil
            if burst >= Self.meaningfulBurst {
                raise(needsInput: false, detail: nil)
            } else {
                // A blip after an unseen result (a redraw, a clock) leaves that result unseen.
                activity = attention ? .done : .idle
            }
        } else if activity == .needsInput {
            // Prompt disappeared without new output (e.g. cleared): nothing is waiting any more.
            activity = .idle
            detail = nil
            attention = false
        } else if activity == .starting, quietFor >= Self.settleTime, now.timeIntervalSince(startedAt ?? now) >= 1.5 {
            // Settled — including programs that never print anything.
            activity = .idle
        }
        return before != (activity, attention, detail)
    }

    /// A prompt on screen that hasn't already been answered.
    private mutating func openPrompt(in lines: [String]) -> String? {
        visiblePrompt = Self.promptLine(in: lines)
        guard let prompt = visiblePrompt else {
            answeredPrompt = nil
            return nil
        }
        // Answers are often echoed onto the prompt's own line, so compare by prefix.
        if let answered = answeredPrompt, prompt.hasPrefix(answered) { return nil }
        return prompt
    }

    private mutating func raise(needsInput: Bool, detail: String?) {
        activity = needsInput ? .needsInput : .done
        self.detail = detail
        if !isBeingViewed { attention = true } else if activity == .done { activity = .idle }
    }

    // MARK: Prompt recognition

    static let promptMarkers = [
        "do you want to", "would you like to", "allow command", "allow once", "always allow",
        "(y/n)", "[y/n]", "[y/n]:", "y/n?", "press enter to continue", "waiting for approval",
        "waiting for your input", "needs your permission", "needs your attention", "❯ 1. yes", "› 1. yes",
        "yes, and don't ask again", "continue? ", "proceed?"
    ]

    static func matchesPrompt(_ lowered: String) -> Bool {
        promptMarkers.contains { lowered.contains($0) }
    }

    /// The most recent on-screen line that looks like a question aimed at the user.
    public static func promptLine(in lines: [String]) -> String? {
        for line in lines.reversed() {
            let lowered = line.lowercased()
            if matchesPrompt(lowered) {
                return line.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "│|╭╮╰╯─ "))).preview(120)
            }
        }
        return nil
    }
}
