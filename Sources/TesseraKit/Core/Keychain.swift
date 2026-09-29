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
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
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

    /// Replaces the value of an existing generic password by service name, keeping its owner's access list.
    @discardableResult
    public static func updateGenericPassword(service: String, value: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        return SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary) == errSecSuccess
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
}
