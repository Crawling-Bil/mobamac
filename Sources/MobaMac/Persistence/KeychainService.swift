import Foundation
import Security

/// Thin wrapper around the macOS Keychain for storing per-profile secrets
/// (passwords, private key passphrases). Nothing sensitive touches the
/// JSON profile store — only this service talks to Security.framework.
struct KeychainService {
    private let service = "com.aldi.mobamac.credentials"

    /// Store or overwrite the secret for a given profile id.
    func setSecret(_ secret: String, for profileID: UUID) throws {
        let account = profileID.uuidString
        let data = Data(secret.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Delete first so this behaves as an upsert.
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status: status)
        }
    }

    func getSecret(for profileID: UUID) throws -> String? {
        let account = profileID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
                return nil
            }
            return secret
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandled(status: status)
        }
    }

    func deleteSecret(for profileID: UUID) throws {
        let account = profileID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status: status)
        }
    }

    enum KeychainError: Error {
        case unhandled(status: OSStatus)
    }
}
