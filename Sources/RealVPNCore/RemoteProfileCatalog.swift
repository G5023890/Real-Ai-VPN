import CryptoKit
import Foundation
import Security

public enum RemoteCatalogRole: String, Codable, CaseIterable, Sendable {
    case user
    case admin
}

public enum RemoteCatalogError: LocalizedError, Equatable {
    case invalidEndpoint
    case adminPasswordRequired
    case adminPasswordNotConfigured
    case invalidAdminPassword
    case invalidResponse
    case invalidSignature
    case expired
    case unsupportedSchema(Int)
    case invalidProfile(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Remote catalog URL is invalid."
        case .adminPasswordRequired: return "Enter the Admin password before synchronizing the Admin catalog."
        case .adminPasswordNotConfigured: return "Set up catalogs/admin-access.json in GitHub before synchronizing the Admin catalog."
        case .invalidAdminPassword: return "The Admin password is incorrect."
        case .invalidResponse: return "The catalog response could not be read."
        case .invalidSignature: return "The catalog signature is not trusted."
        case .expired: return "The catalog manifest has expired."
        case .unsupportedSchema(let version): return "Catalog schema \(version) is not supported."
        case .invalidProfile(let reason): return "Catalog profile is invalid: \(reason)"
        }
    }
}

/// The signed payload stored in the GitHub catalog repository. Its JSON bytes
/// are signed directly; re-serializing JSON is intentionally avoided.
public struct RemoteCatalogManifest: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public var schemaVersion: Int
    public var catalogID: String
    public var role: RemoteCatalogRole
    public var revision: String
    public var generatedAt: Date
    public var expiresAt: Date
    public var profiles: [RemoteCatalogProfile]

    public init(schemaVersion: Int = Self.supportedSchemaVersion, catalogID: String, role: RemoteCatalogRole, revision: String, generatedAt: Date, expiresAt: Date, profiles: [RemoteCatalogProfile]) {
        self.schemaVersion = schemaVersion
        self.catalogID = catalogID
        self.role = role
        self.revision = revision
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
        self.profiles = profiles
    }
}

public struct RemoteCatalogProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var kind: StoredVPNProfile.Kind
    public var regionCode: String?
    public var endpointHost: String?
    public var config: String

    public init(id: String, displayName: String, kind: StoredVPNProfile.Kind, regionCode: String? = nil, endpointHost: String? = nil, config: String) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.regionCode = regionCode
        self.endpointHost = endpointHost
        self.config = config
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, kind, regionCode, endpointHost, config
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        kind = try container.decode(StoredVPNProfile.Kind.self, forKey: .kind)
        regionCode = try container.decodeIfPresent(String.self, forKey: .regionCode)
        endpointHost = try container.decodeIfPresent(String.self, forKey: .endpointHost)
        config = try container.decode(RemoteCatalogConfigurationValue.self, forKey: .config).rawConfiguration
    }

    public func storedProfile() -> StoredVPNProfile {
        StoredVPNProfile(
            id: id,
            displayName: displayName,
            kind: kind,
            regionCode: regionCode,
            endpointHost: endpointHost,
            config: config,
            source: .remoteCatalog,
            remoteProfileID: id
        )
    }
}

/// Catalog generators may store a VLESS configuration as either its raw JSON
/// string or as a nested JSON value. Normalize both forms to the app's stored
/// string representation while retaining the signed bytes for verification.
private enum RemoteCatalogConfigurationValue: Codable {
    case string(String)
    case json(RemoteCatalogJSONValue)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            self = .json(try container.decode(RemoteCatalogJSONValue.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .json(let value): try container.encode(value)
        }
    }

    var rawConfiguration: String {
        switch self {
        case .string(let value): return value
        case .json(let value):
            let data = (try? JSONEncoder.remoteCatalog.encode(value)) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    }
}

private indirect enum RemoteCatalogJSONValue: Codable {
    case object([String: RemoteCatalogJSONValue])
    case array([RemoteCatalogJSONValue])
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([RemoteCatalogJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: RemoteCatalogJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct SignedRemoteCatalogEnvelope: Codable, Equatable, Sendable {
    /// Base64 encoding of the exact UTF-8 manifest JSON that was signed.
    public var payload: String
    /// Base64 or base64url Ed25519 signature of `payload` bytes.
    public var signature: String
}

public struct RemoteCatalogEndpoint: Codable, Equatable, Sendable {
    public var baseURL: URL
    public var signingPublicKey: String

    public init(baseURL: URL, signingPublicKey: String) {
        self.baseURL = baseURL
        self.signingPublicKey = signingPublicKey
    }

    public func catalogURL(for role: RemoteCatalogRole) throws -> URL {
        guard baseURL.scheme == "https", baseURL.host == "raw.githubusercontent.com" else {
            throw RemoteCatalogError.invalidEndpoint
        }
        return baseURL.appendingPathComponent("\(role.rawValue).signed.json")
    }

    public func adminAccessURL() throws -> URL {
        guard baseURL.scheme == "https", baseURL.host == "raw.githubusercontent.com" else {
            throw RemoteCatalogError.invalidEndpoint
        }
        return baseURL.appendingPathComponent("admin-access.json")
    }
}

/// Non-secret GitHub catalog metadata. The optional Admin password is stored
/// separately in Keychain, never in defaults, source control, or app configuration files.
public struct RemoteCatalogConfiguration: Codable, Equatable, Sendable {
    public var catalogID: String
    public var endpoint: RemoteCatalogEndpoint

    public init(catalogID: String, endpoint: RemoteCatalogEndpoint) {
        self.catalogID = catalogID
        self.endpoint = endpoint
    }
}

public struct RemoteCatalogConfigurationStore: Sendable {
    private let key = "com.codex.RealAiVPN.remote-catalog-configuration.v1"
    /// The first GitHub catalog signer used during the 0.98 rollout.  It is
    /// retained only to migrate that public bootstrap record to the current
    /// Catalog Manager signer; it is not an Administrator credential.
    private static let legacyBootstrapSigningPublicKey = "eMINTBlbZFKcsVAN5kB9dDZ+pehmHAAJoZJkS2y+UKU="
    /// Public bootstrap metadata for the first sync. It carries no credential.
    public static let defaultConfiguration = RemoteCatalogConfiguration(
        catalogID: "primary",
        endpoint: RemoteCatalogEndpoint(
            baseURL: URL(string: "https://raw.githubusercontent.com/G5023890/Real-Ai-VPN-Catalog/main/catalogs")!,
            signingPublicKey: "xpBPpRAGUkLYKOKesZzEFNUEkZeiBDOUm+UAvy90lnY="
        )
    )
    public init() {}

    public func load() -> RemoteCatalogConfiguration? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return Self.defaultConfiguration }
        guard let configuration = try? JSONDecoder.remoteCatalog.decode(RemoteCatalogConfiguration.self, from: data) else {
            return Self.defaultConfiguration
        }
        // Older builds could persist an incomplete bootstrap record while the
        // catalog UI was being configured. A missing or malformed public key
        // must never leave the signed catalog unusable. This touches only
        // public bootstrap metadata; the Admin password remains in Keychain.
        let decodedKey = Data(base64Encoded: configuration.endpoint.signingPublicKey)
        let hasValidSigningKey = decodedKey?.count == 32
        if !hasValidSigningKey {
            let repaired = RemoteCatalogConfiguration(
                catalogID: configuration.catalogID.isEmpty ? Self.defaultConfiguration.catalogID : configuration.catalogID,
                endpoint: RemoteCatalogEndpoint(
                    baseURL: configuration.endpoint.baseURL.host == "raw.githubusercontent.com"
                        ? configuration.endpoint.baseURL
                        : Self.defaultConfiguration.endpoint.baseURL,
                    signingPublicKey: Self.defaultConfiguration.endpoint.signingPublicKey
                )
            )
            try? save(repaired)
            return repaired
        }
        // Builds published before Catalog Manager stored the former bootstrap
        // signer. Those installs have no user-selected catalog configuration,
        // so safely move them to the signer of the current public User catalog.
        if configuration.catalogID == Self.defaultConfiguration.catalogID,
           configuration.endpoint.signingPublicKey == Self.legacyBootstrapSigningPublicKey {
            try? save(Self.defaultConfiguration)
            return Self.defaultConfiguration
        }
        // Migrate the original Worker endpoint transparently. Existing users
        // keep their catalog ID and signing key, but no longer depend on a
        // Cloudflare deployment.
        if configuration.endpoint.baseURL.host?.hasSuffix(".workers.dev") == true {
            let migrated = RemoteCatalogConfiguration(
                catalogID: configuration.catalogID,
                endpoint: RemoteCatalogEndpoint(
                    baseURL: Self.defaultConfiguration.endpoint.baseURL,
                    signingPublicKey: configuration.endpoint.signingPublicKey
                )
            )
            try? save(migrated)
            return migrated
        }
        return configuration
    }

    public func save(_ configuration: RemoteCatalogConfiguration) throws {
        let data = try JSONEncoder.remoteCatalog.encode(configuration)
        UserDefaults.standard.set(data, forKey: key)
    }

    public func remove() { UserDefaults.standard.removeObject(forKey: key) }
}

public struct RemoteCatalogFetchResult: Sendable {
    public var manifest: RemoteCatalogManifest?
    public var eTag: String?
    public var notModified: Bool
}

/// A deliberately simple, non-secret access hint for the Admin catalog.
/// The SHA-256 value prevents the password itself from being published, but it
/// is not an authorization boundary: a public GitHub repository cannot protect
/// the Admin envelope from a determined reader. Ed25519 still protects catalog
/// integrity.
public struct RemoteCatalogAdminAccess: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public var schemaVersion: Int
    public var catalogID: String
    public var passwordSHA256: String

    public init(schemaVersion: Int = Self.supportedSchemaVersion, catalogID: String, passwordSHA256: String) {
        self.schemaVersion = schemaVersion
        self.catalogID = catalogID
        self.passwordSHA256 = passwordSHA256
    }
}

public struct RemoteCatalogApplyResult: Equatable, Sendable {
    public var inserted: Int
    public var updated: Int
    public var removed: Int
}

public struct RemoteCatalogClient: Sendable {
    public init() {}

    public func fetch(
        endpoint: RemoteCatalogEndpoint,
        role: RemoteCatalogRole,
        accessToken: String? = nil,
        eTag: String? = nil,
        now: Date = Date()
    ) async throws -> RemoteCatalogFetchResult {
        if role == .admin {
            guard let password = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !password.isEmpty else {
                throw RemoteCatalogError.adminPasswordRequired
            }
            try await verifyAdminPassword(password, endpoint: endpoint)
        }
        let url = try endpoint.catalogURL(for: role)
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let eTag { request.setValue(eTag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteCatalogError.invalidResponse }
        switch http.statusCode {
        case 304: return RemoteCatalogFetchResult(manifest: nil, eTag: eTag, notModified: true)
        case 200..<300: break
        default: throw RemoteCatalogError.invalidResponse
        }
        let envelope = try JSONDecoder.remoteCatalog.decode(SignedRemoteCatalogEnvelope.self, from: data)
        let manifest = try verify(envelope: envelope, publicKey: endpoint.signingPublicKey, now: now)
        guard manifest.role == role else { throw RemoteCatalogError.invalidResponse }
        return RemoteCatalogFetchResult(manifest: manifest, eTag: http.value(forHTTPHeaderField: "ETag"), notModified: false)
    }

    public func verifyAdminPassword(_ password: String, access: RemoteCatalogAdminAccess) throws {
        guard access.schemaVersion == RemoteCatalogAdminAccess.supportedSchemaVersion,
              access.passwordSHA256.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil else {
            throw RemoteCatalogError.invalidResponse
        }
        let digest = SHA256.hash(data: Data(password.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        guard hash.lowercased() == access.passwordSHA256.lowercased() else {
            throw RemoteCatalogError.invalidAdminPassword
        }
    }

    private func verifyAdminPassword(_ password: String, endpoint: RemoteCatalogEndpoint) async throws {
        // GitHub Raw may keep an older small JSON file at an edge for several
        // minutes. A cache-busting request ensures a newly chosen Admin
        // password takes effect immediately without changing the catalog URL.
        guard var components = URLComponents(url: try endpoint.adminAccessURL(), resolvingAgainstBaseURL: false) else {
            throw RemoteCatalogError.invalidEndpoint
        }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "v", value: UUID().uuidString)
        ]
        guard let url = components.url else { throw RemoteCatalogError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteCatalogError.invalidResponse
        }
        if http.statusCode == 404 { throw RemoteCatalogError.adminPasswordNotConfigured }
        guard (200..<300).contains(http.statusCode) else { throw RemoteCatalogError.invalidResponse }
        let access = try JSONDecoder.remoteCatalog.decode(RemoteCatalogAdminAccess.self, from: data)
        try verifyAdminPassword(password, access: access)
    }

    public func verify(envelope: SignedRemoteCatalogEnvelope, publicKey: String, now: Date = Date()) throws -> RemoteCatalogManifest {
        guard let payload = Self.decodeBase64URL(envelope.payload),
              let signature = Self.decodeBase64URL(envelope.signature),
              let keyData = Self.decodeBase64URL(publicKey) else {
            throw RemoteCatalogError.invalidResponse
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        guard key.isValidSignature(signature, for: payload) else { throw RemoteCatalogError.invalidSignature }
        let manifest = try JSONDecoder.remoteCatalog.decode(RemoteCatalogManifest.self, from: payload)
        guard manifest.schemaVersion == RemoteCatalogManifest.supportedSchemaVersion else {
            throw RemoteCatalogError.unsupportedSchema(manifest.schemaVersion)
        }
        guard manifest.expiresAt > now else { throw RemoteCatalogError.expired }
        for profile in manifest.profiles {
            guard !profile.id.isEmpty, !profile.displayName.isEmpty, !profile.config.isEmpty else {
                throw RemoteCatalogError.invalidProfile(profile.id.isEmpty ? "missing id" : "missing configuration")
            }
        }
        return manifest
    }

    private static func decodeBase64URL(_ string: String) -> Data? {
        let normalized = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        return Data(base64Encoded: padded)
    }
}

public struct RemoteCatalogSyncState: Codable, Equatable, Sendable {
    public var eTag: String?
    public var lastSuccessfulSync: Date?
    public var revision: String?

    public init(eTag: String? = nil, lastSuccessfulSync: Date? = nil, revision: String? = nil) {
        self.eTag = eTag
        self.lastSuccessfulSync = lastSuccessfulSync
        self.revision = revision
    }
}

public struct RemoteCatalogSyncStateStore: Sendable {
    private let keyPrefix = "com.codex.RealAiVPN.remote-catalog-state."
    public init() {}

    public func load(catalogID: String) -> RemoteCatalogSyncState {
        guard let data = UserDefaults.standard.data(forKey: keyPrefix + catalogID),
              let state = try? JSONDecoder.remoteCatalog.decode(RemoteCatalogSyncState.self, from: data) else {
            return RemoteCatalogSyncState()
        }
        return state
    }

    public func save(_ state: RemoteCatalogSyncState, catalogID: String) {
        guard let data = try? JSONEncoder.remoteCatalog.encode(state) else { return }
        UserDefaults.standard.set(data, forKey: keyPrefix + catalogID)
    }
}

/// Stores the locally entered Admin password in Keychain. It is intentionally
/// separate from the non-secret GitHub catalog metadata in UserDefaults.
public struct RemoteCatalogAccessCredentialStore: Sendable {
    private let service = "com.local.real-ai-vpn.remote-catalog"
    private let accessGroup: String?

    public init(accessGroup: String? = nil) { self.accessGroup = accessGroup }

    public func save(_ token: String, catalogID: String, role: RemoteCatalogRole) throws {
        let account = "\(catalogID).\(role.rawValue)"
        var query = baseQuery(account: account)
        let data = Data(token.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw VPNProfileStoreError.saveFailed(update) }
        attributes.forEach { query[$0.key] = $0.value }
        let add = SecItemAdd(query as CFDictionary, nil)
        guard add == errSecSuccess else { throw VPNProfileStoreError.saveFailed(add) }
    }

    public func read(catalogID: String, role: RemoteCatalogRole) throws -> String? {
        var query = baseQuery(account: "\(catalogID).\(role.rawValue)")
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw VPNProfileStoreError.readFailed(status)
        }
        return token
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

private extension JSONDecoder {
    static var remoteCatalog: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var remoteCatalog: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
