import Foundation
import Security

public enum WireGuardConfigKeyStoreError: LocalizedError, Equatable {
    case invalidKey
    case saveFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "Enter a standard WireGuard .conf configuration."
        case .saveFailed(let status):
            return "Could not save WireGuard config to Keychain: \(status)."
        case .readFailed(let status):
            return "Could not read WireGuard config from Keychain: \(status)."
        case .deleteFailed(let status):
            return "Could not delete WireGuard config from Keychain: \(status)."
        }
    }
}

public struct WireGuardConfigKeyStore: Sendable {
    public static let sharedAccessGroup = "9FP39GTDT5.com.codex.RealAiVPN"

    private let service = "com.local.real-ai-vpn.wireguard"
    private let account = "wireguard-config"
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
        guard isPlausibleWireGuardConfig(trimmed), let data = trimmed.data(using: .utf8) else {
            throw WireGuardConfigKeyStoreError.invalidKey
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
            throw WireGuardConfigKeyStoreError.saveFailed(updateStatus)
        }

        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw WireGuardConfigKeyStoreError.saveFailed(addStatus)
        }
    }

    public func read() throws -> String? {
        do {
            return try read(using: baseQuery(includeAccessGroup: true))
        } catch WireGuardConfigKeyStoreError.readFailed(let status) where status == errSecItemNotFound {
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
            throw WireGuardConfigKeyStoreError.readFailed(status)
        }

        guard let data = item as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery(includeAccessGroup: true) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WireGuardConfigKeyStoreError.deleteFailed(status)
        }

        if accessGroup != nil {
            let legacyStatus = SecItemDelete(baseQuery(includeAccessGroup: false) as CFDictionary)
            guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else {
                throw WireGuardConfigKeyStoreError.deleteFailed(legacyStatus)
            }
        }
    }

    public func isPlausibleWireGuardConfig(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else {
            return false
        }

        if trimmed.localizedCaseInsensitiveContains("[Interface]"),
           trimmed.localizedCaseInsensitiveContains("[Peer]") {
            return true
        }

        return false
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
