import Foundation
import Security
import CryptoKit

/// Provider secrets live in the login Keychain, scoped to Tessera's service name.
public enum Keychain {
    public static let service = "org.enntity.tessera"
    // An explicitly isolated app instance never reaches the user's login Keychain.
    // Secrets are ephemeral in that instance, including release-build smoke tests.
    private static let isolatedLock = NSLock()
    private static var isolatedValues: [String:String] = [:]
    private static func isolatedKey(account: String, service: String) -> String? {
        guard let directory = ProcessInfo.processInfo.environment["TESSERA_DATA_DIR"] else { return nil }
        return directory + "\n" + service + "\n" + account
    }

    public static func set(_ value: String?, account: String) {
        if let key = isolatedKey(account:account,service:service) {
            isolatedLock.lock(); defer { isolatedLock.unlock() }
            isolatedValues[key] = value?.isEmpty == false ? value : nil
            return
        }
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
        if let key = isolatedKey(account:account,service:service) {
            isolatedLock.lock(); defer { isolatedLock.unlock() }
            return isolatedValues[key]
        }
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
        if let key = isolatedKey(account:account,service:service) {
            isolatedLock.lock(); defer { isolatedLock.unlock() }
            return isolatedValues[key] != nil
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}

public enum Preferences {
    /// App preferences. A development instance pointed at its own data folder (TESSERA_DATA_DIR)
    /// also gets its own preferences, so it can't change the settings of the Tessera you use.
    public static let store: UserDefaults = {
        if let directory = ProcessInfo.processInfo.environment["TESSERA_DATA_DIR"] {
            let digest = SHA256.hash(data:Data(directory.utf8)).map { String(format:"%02x",$0) }.joined()
            if let dev = UserDefaults(suiteName:"org.enntity.tessera.dev." + digest) { return dev }
        }
        return .standard
    }()

    /// A development instance shares the app's bundle id, so it must leave alone what macOS keeps
    /// per app: the saved window frame, and notifications (its own would appear as the app's).
    public static var isDevelopmentCopy: Bool { store !== UserDefaults.standard }
}
