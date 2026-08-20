import Foundation
import Security

public enum VPNProfileStoreError: LocalizedError, Equatable {
    case saveFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)
    case decodeFailed

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Could not save VPN profiles to Keychain: \(status)."
        case .readFailed(let status):
            return "Could not read VPN profiles from Keychain: \(status)."
        case .deleteFailed(let status):
            return "Could not delete VPN profiles from Keychain: \(status)."
        case .decodeFailed:
            return "Stored VPN profiles could not be decoded."
        }
    }
}

public struct StoredVPNProfile: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case wireGuardConfig = "WireGuard Config"
        case singBoxVLESSReality = "VLESS Reality"
        case unknown = "Config"
    }

    /// Identifies who owns a profile. Managed records are supplied by a remote
    /// catalog and may be refreshed or withdrawn by that catalog. Imported
    /// records always remain local to the device.
    public enum Source: String, Codable, Sendable {
        case localImport
        case remoteCatalog
    }

    public var id: String
    public var displayName: String
    public var kind: Kind
    public var regionCode: String?
    public var endpointHost: String?
    public var importedAt: Date
    public var config: String
    public var source: Source
    public var remoteCatalogID: String?
    public var remoteProfileID: String?
    public var remoteRole: String?
    public var remoteRevision: String?

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        kind: Kind,
        regionCode: String? = nil,
        endpointHost: String? = nil,
        importedAt: Date = Date(),
        config: String,
        source: Source = .localImport,
        remoteCatalogID: String? = nil,
        remoteProfileID: String? = nil,
        remoteRole: String? = nil,
        remoteRevision: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.regionCode = regionCode
        self.endpointHost = endpointHost
        self.importedAt = importedAt
        self.config = config
        self.source = source
        self.remoteCatalogID = remoteCatalogID
        self.remoteProfileID = remoteProfileID
        self.remoteRole = remoteRole
        self.remoteRevision = remoteRevision
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, kind, regionCode, endpointHost, importedAt, config
        case source, remoteCatalogID, remoteProfileID, remoteRole, remoteRevision
    }

    /// Older installed releases stored no provenance fields. Decode them as
    /// local imports so an app update never loses access to user profiles.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        kind = try container.decode(Kind.self, forKey: .kind)
        regionCode = try container.decodeIfPresent(String.self, forKey: .regionCode)
        endpointHost = try container.decodeIfPresent(String.self, forKey: .endpointHost)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        config = try container.decode(String.self, forKey: .config)
        source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .localImport
        remoteCatalogID = try container.decodeIfPresent(String.self, forKey: .remoteCatalogID)
        remoteProfileID = try container.decodeIfPresent(String.self, forKey: .remoteProfileID)
        remoteRole = try container.decodeIfPresent(String.self, forKey: .remoteRole)
        remoteRevision = try container.decodeIfPresent(String.self, forKey: .remoteRevision)
    }
}

public struct VPNProfileCollection: Codable, Equatable, Sendable {
    public var activeProfileID: String?
    public var profiles: [StoredVPNProfile]

    public init(activeProfileID: String? = nil, profiles: [StoredVPNProfile] = []) {
        self.activeProfileID = activeProfileID
        self.profiles = profiles
    }

    public var activeProfile: StoredVPNProfile? {
        guard let activeProfileID else {
            return profiles.first
        }

        return profiles.first { $0.id == activeProfileID } ?? profiles.first
    }
}

/// Describes the non-destructive import of profiles saved by releases before 0.98.
/// The previous store used a different Keychain service name, so iOS treats it as
/// a separate record after an app update.
public enum VPNProfileMigrationResult: Equatable, Sendable {
    case notNeeded
    case migrated(Int)
}

public struct VPNProfileStore: Sendable {
    private let service = "com.local.real-ai-vpn.profiles"
    private let account = "profiles-v1"
    private let legacyService = "com.local.real-ai-vpn.amnezia.profiles"
    private let legacyMigrationDefaultsKey = "com.codex.RealAiVPN.migrated-amnezia-profile-store-v1"
    private let accessGroup: String?
    private let allowsAuthenticationUI: Bool

    public init(
        accessGroup: String? = nil,
        allowsAuthenticationUI: Bool = true
    ) {
        self.accessGroup = accessGroup
        self.allowsAuthenticationUI = allowsAuthenticationUI
    }

    public func load() throws -> VPNProfileCollection {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowsAuthenticationUI {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return VPNProfileCollection()
        }

        guard status == errSecSuccess else {
            throw VPNProfileStoreError.readFailed(status)
        }

        guard let data = item as? Data else {
            throw VPNProfileStoreError.decodeFailed
        }

        do {
            return try JSONDecoder().decode(VPNProfileCollection.self, from: data)
        } catch {
            throw VPNProfileStoreError.decodeFailed
        }
    }

    /// Copies profiles from the pre-0.98 Keychain service once. The legacy item
    /// is deliberately retained as a recovery copy.
    ///
    /// VLESS Reality profiles remain usable. Legacy AWG and token entries are
    /// retained as opaque configs rather than being discarded or mislabelled as
    /// standard WireGuard profiles.
    @discardableResult
    public func migrateLegacyProfilesIfNeeded() throws -> VPNProfileMigrationResult {
        guard !UserDefaults.standard.bool(forKey: legacyMigrationDefaultsKey) else {
            return .notNeeded
        }

        guard let legacyCollection = try loadLegacyCollection(),
              !legacyCollection.profiles.isEmpty else {
            return .notNeeded
        }

        var collection = try load()
        let existingIDs = Set(collection.profiles.map(\.id))
        let importedProfiles = legacyCollection.profiles.compactMap { legacyProfile -> StoredVPNProfile? in
            guard !existingIDs.contains(legacyProfile.id) else {
                return nil
            }
            return StoredVPNProfile(
                id: legacyProfile.id,
                displayName: legacyProfile.displayName,
                kind: legacyProfile.kind == StoredLegacyVPNProfile.Kind.singBoxVLESSReality.rawValue
                    ? .singBoxVLESSReality
                    : .unknown,
                regionCode: legacyProfile.regionCode,
                endpointHost: legacyProfile.endpointHost,
                importedAt: legacyProfile.importedAt,
                config: legacyProfile.config
            )
        }
        if !importedProfiles.isEmpty {
            collection.profiles.append(contentsOf: importedProfiles)
            if collection.activeProfileID == nil,
               collection.profiles.contains(where: { $0.id == legacyCollection.activeProfileID }) {
                collection.activeProfileID = legacyCollection.activeProfileID
            }
            try save(collection)
        }
        UserDefaults.standard.set(true, forKey: legacyMigrationDefaultsKey)
        return .migrated(importedProfiles.count)
    }

    public func save(_ collection: VPNProfileCollection) throws {
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
            throw VPNProfileStoreError.saveFailed(updateStatus)
        }

        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw VPNProfileStoreError.saveFailed(addStatus)
        }
    }

    public func upsert(_ profile: StoredVPNProfile, makeActive: Bool = true) throws {
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

    public func renameProfile(id: String, displayName: String) throws {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return
        }

        var collection = try load()
        guard let index = collection.profiles.firstIndex(where: { $0.id == id }) else {
            return
        }

        collection.profiles[index].displayName = trimmedName
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
            throw VPNProfileStoreError.deleteFailed(status)
        }
    }

    /// Applies a complete catalog revision as one Keychain transaction.
    /// Only profiles previously owned by this catalog are removed. User imports
    /// and profiles from other catalogs are deliberately preserved.
    @discardableResult
    public func synchronizeRemoteCatalog(
        catalogID: String,
        role: String,
        revision: String,
        profiles: [StoredVPNProfile]
    ) throws -> RemoteCatalogApplyResult {
        var collection = try load()
        let remoteProfiles = profiles.map { profile in
            StoredVPNProfile(
                id: remoteProfileStorageID(catalogID: catalogID, role: role, remoteID: profile.remoteProfileID ?? profile.id),
                displayName: profile.displayName,
                kind: profile.kind,
                regionCode: profile.regionCode,
                endpointHost: profile.endpointHost,
                importedAt: profile.importedAt,
                config: profile.config,
                source: .remoteCatalog,
                remoteCatalogID: catalogID,
                remoteProfileID: profile.remoteProfileID ?? profile.id,
                remoteRole: role,
                remoteRevision: revision
            )
        }
        let incomingIDs = Set(remoteProfiles.map(\.id))
        let existingCatalogIDs = Set(collection.profiles.compactMap { profile in
            profile.source == .remoteCatalog
                && profile.remoteCatalogID == catalogID
                && profile.remoteRole == role ? profile.id : nil
        })
        let removedIDs = existingCatalogIDs.subtracting(incomingIDs)
        let insertedIDs = incomingIDs.subtracting(existingCatalogIDs)
        let updatedIDs = incomingIDs.intersection(existingCatalogIDs)

        collection.profiles.removeAll { removedIDs.contains($0.id) }
        for profile in remoteProfiles {
            if let index = collection.profiles.firstIndex(where: { $0.id == profile.id }) {
                collection.profiles[index] = profile
            } else {
                collection.profiles.append(profile)
            }
        }
        if let activeProfileID = collection.activeProfileID, removedIDs.contains(activeProfileID) {
            collection.activeProfileID = collection.profiles.first?.id
        }
        try save(collection)
        return RemoteCatalogApplyResult(
            inserted: insertedIDs.count,
            updated: updatedIDs.count,
            removed: removedIDs.count
        )
    }

    private func remoteProfileStorageID(catalogID: String, role: String, remoteID: String) -> String {
        "remote:\(catalogID):\(role):\(remoteID)"
    }

    private func baseQuery() -> [String: Any] {
        baseQuery(service: service)
    }

    private func legacyBaseQuery() -> [String: Any] {
        baseQuery(service: legacyService)
    }

    private func baseQuery(service: String) -> [String: Any] {
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

    private func loadLegacyCollection() throws -> StoredLegacyVPNProfileCollection? {
        var query = legacyBaseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowsAuthenticationUI {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw VPNProfileStoreError.readFailed(status)
        }

        guard let data = item as? Data else {
            throw VPNProfileStoreError.decodeFailed
        }

        do {
            return try JSONDecoder().decode(StoredLegacyVPNProfileCollection.self, from: data)
        } catch {
            throw VPNProfileStoreError.decodeFailed
        }
    }
}

private struct StoredLegacyVPNProfileCollection: Codable, Sendable {
    var activeProfileID: String?
    var profiles: [StoredLegacyVPNProfile]
}

private struct StoredLegacyVPNProfile: Codable, Sendable {
    enum Kind: String {
        case singBoxVLESSReality = "VLESS Reality"
    }

    var id: String
    var displayName: String
    var kind: String
    var regionCode: String?
    var endpointHost: String?
    var importedAt: Date
    var config: String
}
