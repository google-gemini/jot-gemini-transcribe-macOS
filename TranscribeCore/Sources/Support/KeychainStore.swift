import Foundation
import Security

/// API-key storage per TN3137: SecItem + data-protection keychain when the build
/// carries the keychain-access-groups entitlement (provisioned/notarized builds),
/// with a graceful fallback to the login keychain for dev and fork builds that
/// lack it (errSecMissingEntitlement, -34018). Never UserDefaults/JSON
/// (Superwhisper's documented failure).
public enum KeychainStore {
    private static let service = "com.google.transcribe"
    private static let account = "gemini-api-key"

    private static func baseQuery(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    public static func loadAPIKey() -> String? {
        for dataProtection in [true, false] {
            var query = baseQuery(dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    @discardableResult
    public static func saveAPIKey(_ key: String) -> Bool {
        deleteAPIKey()
        for dataProtection in [true, false] {
            var attributes = baseQuery(dataProtection: dataProtection)
            attributes[kSecAttrLabel as String] = "Google Transcribe — Gemini API key"
            attributes[kSecValueData as String] = Data(key.utf8)
            if dataProtection {
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
            let status = SecItemAdd(attributes as CFDictionary, nil)
            if status == errSecSuccess {
                Log.permissions.info("KeychainStore: key saved (\(dataProtection ? "data-protection" : "login", privacy: .public) keychain)")
                return true
            }
            if status != errSecMissingEntitlement {
                Log.permissions.error("KeychainStore: save failed (\(status))")
                return false
            }
            // -34018: unprovisioned build — fall through to the login keychain.
        }
        return false
    }

    @discardableResult
    public static func deleteAPIKey() -> Bool {
        var deleted = false
        for dataProtection in [true, false] {
            let status = SecItemDelete(baseQuery(dataProtection: dataProtection) as CFDictionary)
            deleted = deleted || status == errSecSuccess
        }
        return deleted
    }

    /// Dev bootstrap until onboarding (M7): if ~/.config/google-transcribe/apikey.dev
    /// exists, migrate its contents into the Keychain and DELETE the file. Lets
    /// contributors seed a key without any UI, without leaving plaintext behind.
    public static func migrateDevKeyFileIfPresent() {
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/google-transcribe/apikey.dev")
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if saveAPIKey(key) {
            try? FileManager.default.removeItem(at: fileURL)
            Log.permissions.info("KeychainStore: migrated dev key file into Keychain (file deleted)")
        }
    }
}
