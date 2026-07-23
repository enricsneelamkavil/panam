import Foundation
import Observation
import Security

/// Minimal Keychain-backed flag storage.
enum KeychainStore {
    private static let service = "enric.Plush"

    static func bool(forKey key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return false }
        return data.first == 1
    }

    static func set(_ value: Bool, forKey key: String) {
        let data = Data([value ? 1 : 0])
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}

@Observable
final class AuthState {
    /// In-memory only — every launch and every return from background
    /// starts locked.
    var isUnlocked = false

    /// Persisted marker of the first successful unlock. Not used for gating
    /// (every launch requires unlock regardless) — kept for a future
    /// "Reset Plush" style feature.
    var hasCompletedFirstUnlock: Bool {
        get { KeychainStore.bool(forKey: Self.firstUnlockKey) }
        set { KeychainStore.set(newValue, forKey: Self.firstUnlockKey) }
    }

    private static let firstUnlockKey = "hasCompletedFirstUnlock"
}
