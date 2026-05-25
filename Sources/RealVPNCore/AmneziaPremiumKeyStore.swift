import Foundation
import Security

public enum AmneziaPremiumKeyStoreError: LocalizedError, Equatable {
    case invalidKey
    case saveFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "Enter a valid Amnezia Premium key or vpn:// import link."
        case .saveFailed(let status):
            return "Could not save Amnezia key to Keychain: \(status)."
        case .readFailed(let status):
            return "Could not read Amnezia key from Keychain: \(status)."
        case .deleteFailed(let status):
            return "Could not delete Amnezia key from Keychain: \(status)."
        }
    }
}

public struct AmneziaPremiumKeyStore: Sendable {
    public static let sharedAccessGroup = "9FP39GTDT5.com.codex.RealAiVPN"

    private let service = "com.local.real-ai-vpn.amnezia"
    private let account = "premium-key"
    private let accessGroup: String?
    private let allowsLegacyFallback: Bool
    private let allowsAuthenticationUI: Bool

    public init(
        accessGroup: String? = nil,
        allowsLegacyFallback: Bool = true,
        allowsAuthenticationUI: Bool = true
    ) {
        self.accessGroup = accessGroup
        self.allowsLegacyFallback = allowsLegacyFallback
        self.allowsAuthenticationUI = allowsAuthenticationUI
    }

    public func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPlausibleAmneziaKey(trimmed), let data = trimmed.data(using: .utf8) else {
            throw AmneziaPremiumKeyStoreError.invalidKey
        }

        let query: [String: Any] = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            throw AmneziaPremiumKeyStoreError.saveFailed(updateStatus)
        }

        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AmneziaPremiumKeyStoreError.saveFailed(addStatus)
        }
    }

    public func read() throws -> String? {
        do {
            return try read(using: baseQuery(includeAccessGroup: true))
        } catch AmneziaPremiumKeyStoreError.readFailed(let status) where status == errSecItemNotFound {
            return nil
        } catch {
            throw error
        }
    }

    private func read(using baseQuery: [String: Any]) throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowsAuthenticationUI {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            if accessGroup != nil, baseQuery[kSecAttrAccessGroup as String] != nil {
                guard allowsLegacyFallback else {
                    return nil
                }
                let legacyValue = try read(using: self.baseQuery(includeAccessGroup: false))
                if let legacyValue {
                    try? save(legacyValue)
                }
                return legacyValue
            }

            return nil
        }

        guard status == errSecSuccess else {
            throw AmneziaPremiumKeyStoreError.readFailed(status)
        }

        guard let data = item as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery(includeAccessGroup: true) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AmneziaPremiumKeyStoreError.deleteFailed(status)
        }

        if accessGroup != nil {
            let legacyStatus = SecItemDelete(baseQuery(includeAccessGroup: false) as CFDictionary)
            guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else {
                throw AmneziaPremiumKeyStoreError.deleteFailed(legacyStatus)
            }
        }
    }

    public func isPlausibleAmneziaKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else {
            return false
        }

        if trimmed.hasPrefix("vpn://") {
            return true
        }

        if trimmed.localizedCaseInsensitiveContains("[Interface]"),
           trimmed.localizedCaseInsensitiveContains("[Peer]") {
            return true
        }

        return trimmed.range(of: #"^[A-Za-z0-9_\-:.=+/]{16,}$"#, options: .regularExpression) != nil
    }

    private func baseQuery() -> [String: Any] {
        baseQuery(includeAccessGroup: true)
    }

    private func baseQuery(includeAccessGroup: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if includeAccessGroup, let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        return query
    }
}
