import Foundation
import Security

/// Secrets in the login Keychain, one generic-password item per account: a
/// connection's password (keyed by its id), its key passphrase, and proxy
/// passwords.
///
/// Keeping them out of `connections.json` is the whole point: that file is
/// plain JSON in Application Support and gets swept up by backups and sync.
enum KeychainStore {
    private static let service = "com.glassftp.credentials"

    static func save(password: String, for id: UUID) throws {
        try save(password, account: id.uuidString)
    }

    static func password(for id: UUID) -> String? {
        secret(account: id.uuidString)
    }

    static func delete(for id: UUID) {
        delete(account: id.uuidString)
    }

    /// Account names for the other secrets a connection can carry.
    static func passphraseAccount(for id: UUID) -> String { "\(id.uuidString).passphrase" }
    static func proxyAccount(for id: UUID) -> String { "\(id.uuidString).proxy" }

    /// Stores `secret`, or removes the item when it is empty.
    static func store(_ secret: String, account: String) {
        guard !secret.isEmpty else {
            delete(account: account)
            return
        }
        do {
            try save(secret, account: account)
        } catch {
            NSLog("GlassFTP: could not store secret in Keychain: \(error.localizedDescription)")
        }
    }

    static func save(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // SecItemAdd fails on an existing item, so update first and fall back
        // to adding.
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw error(updateStatus) }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        insert[kSecAttrLabel as String] = "GlassFTP"
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw error(addStatus) }
    }

    static func secret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func error(_ status: OSStatus) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String?
        return NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: message ?? "Keychain error \(status)"]
        )
    }
}
