import Foundation
import Security

/// 钥匙串存储抽象：服务层依赖此协议，测试可注入内存实现。
///
/// 契约与真实 Keychain 语义一致：
/// - 读写删除通过 Bool/Optional 报告结果，不抛错（权限不足等失败返回 false/nil）；
/// - 删除不存在的 key 视为成功（对应 errSecItemNotFound）。
public protocol KeychainStoring: Sendable {
    @discardableResult func setString(_ value: String, for key: String) -> Bool
    func string(for key: String) -> String?
    @discardableResult func setData(_ data: Data, for key: String) -> Bool
    func data(for key: String) -> Data?
    @discardableResult func delete(for key: String) -> Bool
    @discardableResult func deleteAll() -> Bool
    @discardableResult func setPhone(_ phone: String, for accountId: UUID) -> Bool
    func phone(for accountId: UUID) -> String?
    @discardableResult func deletePhone(for accountId: UUID) -> Bool
}

/// 基于 macOS Keychain 的敏感凭据存储。
///
/// 首期主要用于存储完整手机号（展示对照用）与后续可能的 PAT。
/// SQLite 中不保存任何敏感明文。
public final class KeychainService: Sendable {
    private let service: String

    public init(service: String = "com.agentaccountmanager") {
        self.service = service
    }

    // MARK: - String 读写

    /// 保存字符串到 Keychain。
    @discardableResult
    public func setString(_ value: String, for key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return setData(data, for: key)
    }

    /// 读取 Keychain 中的字符串。
    public func string(for key: String) -> String? {
        guard let data = data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Data 读写

    /// 保存数据到 Keychain。
    @discardableResult
    public func setData(_ data: Data, for key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]

        // 先删除旧值，再写入
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// 读取 Keychain 中的数据。
    public func data(for key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    // MARK: - 删除

    /// 删除指定 key 的凭据。
    @discardableResult
    public func delete(for key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// 删除本应用写入的全部凭据（清空本地数据时使用）。
    @discardableResult
    public func deleteAll() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return true
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return false
        }

        var allDeleted = true
        for item in items {
            if let account = item[kSecAttrAccount as String] as? String,
               !delete(for: account) {
                allDeleted = false
            }
        }
        return allDeleted
    }

    // MARK: - 完整手机号存取

    private static func phoneKey(for accountId: UUID) -> String {
        "phone:\(accountId.uuidString)"
    }

    /// 保存某账号的完整手机号到 Keychain。
    @discardableResult
    public func setPhone(_ phone: String, for accountId: UUID) -> Bool {
        setString(phone, for: Self.phoneKey(for: accountId))
    }

    /// 读取某账号的完整手机号。
    public func phone(for accountId: UUID) -> String? {
        string(for: Self.phoneKey(for: accountId))
    }

    /// 删除某账号的完整手机号。
    @discardableResult
    public func deletePhone(for accountId: UUID) -> Bool {
        delete(for: Self.phoneKey(for: accountId))
    }
}

extension KeychainService: KeychainStoring {}
