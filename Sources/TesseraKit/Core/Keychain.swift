import Foundation
import Security

/// Provider secrets live in the login Keychain, scoped to Tessera's service name.
public enum Keychain {
    public static let service = "org.enntity.tessera"

    public static func set(_ value: String?, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    public static func get(account: String, service: String = Keychain.service) -> String? {
        try? read(account: account, service: service)
    }

    /// The item's secret, or nil when there is no such item. Throws when it exists but can't be read
    /// (e.g. access denied), so that is never mistaken for "absent" and overwritten.
    public static func read(account: String, service: String = Keychain.service) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return String(data: data, encoding: .utf8)
    }

    /// Whether the item exists. Reads no secret, so it never raises a Keychain prompt.
    public static func contains(account: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Any generic password by service name alone (used to read Claude Code's own sign-in).
    public static func firstGenericPassword(service: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public enum Preferences {
    /// App preferences. A development instance pointed at its own data folder (TESSERA_DATA_DIR)
    /// also gets its own preferences, so it can't change the settings of the Tessera you use.
    public static let store: UserDefaults = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TESSERA_DATA_DIR"] != nil,
           let dev = UserDefaults(suiteName: "org.enntity.tessera.dev") { return dev }
        #endif
        return .standard
    }()

    /// A development instance shares the app's bundle id, so it must leave alone what macOS keeps
    /// per app: the saved window frame, and notifications (its own would appear as the app's).
    public static var isDevelopmentCopy: Bool { store !== UserDefaults.standard }
}
