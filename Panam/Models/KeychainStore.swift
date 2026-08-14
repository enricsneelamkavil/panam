import Foundation
import Security

/// Minimal Keychain-backed flag storage.
enum KeychainStore {
    private static let service = "enric.Panam"

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
        set(Data([value ? 1 : 0]), forKey: key)
    }

    static func string(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, forKey key: String) {
        set(Data(value.utf8), forKey: key)
    }

    // MARK: - Statement PDF passwords

    /// Password-protected bank/card statements use a per-issuer convention
    /// (DOB, PAN, etc.) that's stable for a given account over time, so it's
    /// worth letting the user save it once — keyed by the account's last-4
    /// digits (rather than its SwiftData persistentModelID) since that's
    /// what survives an account edit/delete-recreate and is already how
    /// StatementReconciler matches statement lines back to an Account. Like
    /// every other credential in this app, it lives in Keychain only — never
    /// in a SwiftData model.
    private static func statementPasswordKey(lastFourDigits: String) -> String {
        "statementPassword_\(lastFourDigits)"
    }

    static func statementPassword(forLastFour lastFourDigits: String) -> String? {
        string(forKey: statementPasswordKey(lastFourDigits: lastFourDigits))
    }

    static func setStatementPassword(_ password: String, forLastFour lastFourDigits: String) {
        set(password, forKey: statementPasswordKey(lastFourDigits: lastFourDigits))
    }

    private static func set(_ data: Data, forKey key: String) {
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
