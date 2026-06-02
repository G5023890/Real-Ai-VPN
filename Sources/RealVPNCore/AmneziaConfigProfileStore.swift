import Foundation
import Security

public enum AmneziaConfigProfileStoreError: LocalizedError, Equatable {
    case saveFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)
    case decodeFailed

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Could not save Amnezia profiles to Keychain: \(status)."
        case .readFailed(let status):
            return "Could not read Amnezia profiles from Keychain: \(status)."
        case .deleteFailed(let status):
            return "Could not delete Amnezia profiles from Keychain: \(status)."
        case .decodeFailed:
            return "Stored Amnezia profiles could not be decoded."
        }
    }
}

public struct StoredAmneziaConfigProfile: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case awgConfig = "AWG Config"
        case singBoxVLESSReality = "VLESS Reality"
        case premiumToken = "Premium Token"
        case unknown = "Config"
    }

    public var id: String
    public var displayName: String
    public var kind: Kind
    public var regionCode: String?
    public var endpointHost: String?
    public var importedAt: Date
    public var config: String

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        kind: Kind,
        regionCode: String? = nil,
        endpointHost: String? = nil,
        importedAt: Date = Date(),
        config: String
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.regionCode = regionCode
        self.endpointHost = endpointHost
        self.importedAt = importedAt
        self.config = config
    }
}

public struct AmneziaConfigProfileCollection: Codable, Equatable, Sendable {
    public var activeProfileID: String?
    public var profiles: [StoredAmneziaConfigProfile]

    public init(activeProfileID: String? = nil, profiles: [StoredAmneziaConfigProfile] = []) {
        self.activeProfileID = activeProfileID
        self.profiles = profiles
    }

    public var activeProfile: StoredAmneziaConfigProfile? {
        guard let activeProfileID else {
            return profiles.first
        }

        return profiles.first { $0.id == activeProfileID } ?? profiles.first
    }
}

public struct AmneziaConfigProfileStore: Sendable {
    private let service = "com.local.real-ai-vpn.amnezia.profiles"
    private let account = "profiles-v1"
    private let accessGroup: String?
    private let allowsAuthenticationUI: Bool

    public init(
        accessGroup: String? = nil,
        allowsAuthenticationUI: Bool = true
    ) {
        self.accessGroup = accessGroup
        self.allowsAuthenticationUI = allowsAuthenticationUI
    }

    public func load() throws -> AmneziaConfigProfileCollection {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowsAuthenticationUI {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return AmneziaConfigProfileCollection()
        }

        guard status == errSecSuccess else {
            throw AmneziaConfigProfileStoreError.readFailed(status)
        }

        guard let data = item as? Data else {
            throw AmneziaConfigProfileStoreError.decodeFailed
        }

        do {
            return try JSONDecoder().decode(AmneziaConfigProfileCollection.self, from: data)
        } catch {
            throw AmneziaConfigProfileStoreError.decodeFailed
        }
    }

    public func save(_ collection: AmneziaConfigProfileCollection) throws {
        let data = try JSONEncoder().encode(collection)
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            throw AmneziaConfigProfileStoreError.saveFailed(updateStatus)
        }

        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AmneziaConfigProfileStoreError.saveFailed(addStatus)
        }
    }

    public func upsert(_ profile: StoredAmneziaConfigProfile, makeActive: Bool = true) throws {
        var collection = try load()
        if let index = collection.profiles.firstIndex(where: { $0.id == profile.id }) {
            collection.profiles[index] = profile
        } else {
            collection.profiles.append(profile)
        }

        if makeActive || collection.activeProfileID == nil {
            collection.activeProfileID = profile.id
        }

        try save(collection)
    }

    public func setActiveProfile(id: String?) throws {
        var collection = try load()
        collection.activeProfileID = id
        try save(collection)
    }

    public func deleteProfile(id: String) throws {
        var collection = try load()
        collection.profiles.removeAll { $0.id == id }
        if collection.activeProfileID == id {
            collection.activeProfileID = collection.profiles.first?.id
        }
        try save(collection)
    }

    public func deleteAll() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AmneziaConfigProfileStoreError.deleteFailed(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        return query
    }
}
