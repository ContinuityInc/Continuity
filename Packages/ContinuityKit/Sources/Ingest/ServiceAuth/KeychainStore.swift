import Foundation
import Security

/// Where connected-account tokens live. The Keychain in production; an in-memory dictionary for
/// tests (and for previews, where Keychain access prompts or fails).
protocol CredentialStore: Sendable {
    func load(account: String) -> Data?
    func save(_ data: Data, account: String)
    func delete(account: String)
}

/// Generic-password Keychain items under one service name, one per connected account.
/// `kSecAttrAccessibleAfterFirstUnlock` so a background sync tick after a reboot can still
/// refresh tokens; items are not synced to iCloud Keychain (a token tied to this install).
struct KeychainStore: CredentialStore {
    private static let service = "com.continuity.app.oauth"

    func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func save(_ data: Data, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(base.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Test/preview double — nothing persists past the process.
final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    init() {}

    func load(account: String) -> Data? { lock.withLock { items[account] } }
    func save(_ data: Data, account: String) { lock.withLock { items[account] = data } }
    func delete(account: String) { _ = lock.withLock { items.removeValue(forKey: account) } }
}
