import Foundation
import Security

/// Only Ghostty's own AI credentials are stored here, never Pi's global login.
enum TerminalAICredentials {
    private static let service = "com.mitchellh.ghostty.terminal-ai"

    static func load(provider: String) -> String? {
        guard !provider.isEmpty else { return nil }
        var query = attributes(provider: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func store(_ apiKey: String, provider: String) throws {
        guard !provider.isEmpty else { return }
        let query = attributes(provider: provider)
        if apiKey.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw keychainError(status)
            }
            return
        }
        let values = [kSecValueData as String: Data(apiKey.utf8)]
        let updated = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw keychainError(updated) }
        var item = query
        item.merge(values) { _, value in value }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw keychainError(added) }
    }

    private static func attributes(provider: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider
        ]
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "Could not save the AI credential in Keychain."])
    }
}
