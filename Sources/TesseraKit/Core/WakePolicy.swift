import Foundation

/// Who may have a message typed into an idle agent tile without the user approving each one
/// (Settings → Agents): only the overseer, it and the other agents on this board, or no one.
public enum WakePolicy: String, Codable, Sendable, CaseIterable {
    case overseer
    case overseerAndPeers
    case askAlways

    /// Who sent the message, as far as the board can tell: the overseer tile, another tile on
    /// this board, or anything else (an agent elsewhere, an unknown caller).
    public enum SenderKind: String, Codable, Sendable {
        case overseer, peer, other
    }

    /// Whether `kind` may be typed without asking; a tile that opted out always asks, and a
    /// sender the board can't place always asks.
    public func allows(_ kind: SenderKind, tileOptedOut: Bool) -> Bool {
        if tileOptedOut || kind == .other { return false }
        switch self {
        case .overseer: return kind == .overseer
        case .overseerAndPeers: return true
        case .askAlways: return false
        }
    }

    public static let prefKey = "tessera.wakePolicy"
    static let legacyKey = "tessera.agentsMayType"

    /// The stored setting, defaulting to overseer-only. The switch it replaces
    /// (`tessera.agentsMayType`, any sender could type) migrates to overseer and peers when on.
    public static var stored: WakePolicy {
        if let raw = Preferences.store.string(forKey: prefKey), let policy = WakePolicy(rawValue: raw) { return policy }
        let migrated: WakePolicy = Preferences.store.bool(forKey: legacyKey) ? .overseerAndPeers : .overseer
        Preferences.store.set(migrated.rawValue, forKey: prefKey)
        Preferences.store.removeObject(forKey: legacyKey)
        return migrated
    }

    public func save() { Preferences.store.set(rawValue, forKey: Self.prefKey) }
}
