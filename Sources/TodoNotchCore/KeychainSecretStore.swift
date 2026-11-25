import Foundation
import Security

public protocol SecretStoreProtocol: Sendable {
    func saveSecret(_ value: String, account: String) throws
    func loadSecret(account: String) -> String?
    func deleteSecret(account: String)
}

public enum SecretAccount {
    public static let webhookURL = "webhook_url"
}

public final class KeychainSecretStore: SecretStoreProtocol, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.libo.TodoNotch") {
        self.service = service
    }

    public func saveSecret(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "KeychainSecretStore", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Keychain 写入失败（OSStatus=\(status)）"
            ])
        }
    }

    public func loadSecret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func deleteSecret(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

public final class InMemorySecretStore: SecretStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init() {}

    public func saveSecret(_ value: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account] = value
    }

    public func loadSecret(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[account]
    }

    public func deleteSecret(account: String) {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: account)
    }
}
