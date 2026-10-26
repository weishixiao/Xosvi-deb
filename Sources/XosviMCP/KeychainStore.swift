import Foundation
import Security

/// 统一 Keychain 存储封装。
/// 用于替代 UserDefaults 明文存储 token/apiKey/secret 等敏感凭据。
/// 越狱/TrollStore 环境下 UserDefaults 可被任意进程读取，Keychain 受沙盒保护。
///
/// 用法：
///   try? KeychainStore.shared.set("token-value", forKey: "gateway_token")
///   let v = try? KeychainStore.shared.string(forKey: "gateway_token")
final class KeychainStore {
    static let shared = KeychainStore()

    /// 统一 access group（nil = 默认 app group，TrollStore 环境多数情况为 nil 最稳）
    private let service = "com.xosvi.keychain"

    private init() {}

    private func baseQuery(forKey key: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        // TrollStore 下 access group 常不可用，注释保留以便需要时开启
        // if let group = Bundle.main.object(forInfoDictionaryKey: "KeychainAccessGroup") as? String {
        //     q[kSecAttrAccessGroup as String] = group
        // }
        return q
    }

    // MARK: - 读

    func string(forKey key: String) -> String? {
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func data(forKey key: String) -> Data? {
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    // MARK: - 写

    @discardableResult
    func set(_ value: String, forKey key: String) -> Bool {
        set(Data(value.utf8), forKey: key)
    }

    @discardableResult
    func set(_ value: Data, forKey key: String) -> Bool {
        var query = baseQuery(forKey: key)
        _ = delete(key)  // 先删旧值，再写入，避免 errSecDuplicateItem

        var attrs = query
        attrs[kSecValueData as String] = value
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - 删

    @discardableResult
    func delete(_ key: String) -> Bool {
        let query = baseQuery(forKey: key)
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// v6.2.1：清空本 service 下全部 Keychain 项（"重置所有数据"用）
    @discardableResult
    func clearAll() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}