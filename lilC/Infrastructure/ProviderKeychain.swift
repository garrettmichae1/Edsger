import Foundation
import Security

protocol ProviderCredentialStoring: Sendable {
    func read(_ provider: BYOKProvider) throws -> String?
    func save(_ key: String, for provider: BYOKProvider) throws
    func remove(_ provider: BYOKProvider) throws
}

struct ProviderKeychain: ProviderCredentialStoring {
    private func query(_ provider: BYOKProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "app.lilc.byok", kSecAttrAccount as String: provider.rawValue,
         kSecAttrSynchronizable as String: false]
    }
    func read(_ provider: BYOKProvider) throws -> String? {
        var query = query(provider)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) else { throw BYOKError.keychain }
        return key
    }
    func save(_ key: String, for provider: BYOKProvider) throws {
        let key = try BYOKSecretValidation.clean(key)
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query(provider) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query(provider); entry.merge(attributes) { _, value in value }
            guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw BYOKError.keychain }
        } else if status != errSecSuccess { throw BYOKError.keychain }
        // Updating never deletes a working credential before the new one is stored.
    }
    func remove(_ provider: BYOKProvider) throws {
        let status = SecItemDelete(query(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BYOKError.keychain }
    }
}
