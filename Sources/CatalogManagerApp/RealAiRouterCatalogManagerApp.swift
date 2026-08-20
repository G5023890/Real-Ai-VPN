import AppKit
import CryptoKit
import Security
import SwiftUI

@main
struct RealAiRouterCatalogManagerApp: App {
    @StateObject private var model = CatalogManagerModel()

    var body: some Scene {
        WindowGroup("Real Ai Router Catalog Manager") {
            CatalogManagerView(model: model)
                .frame(minWidth: 900, minHeight: 620)
        }
    }
}

enum CatalogRole: String, Codable, CaseIterable, Identifiable {
    case user
    case admin

    var id: String { rawValue }
    var title: String { self == .user ? "User" : "Admin" }
    var remoteFileName: String { "\(rawValue).signed.json" }
}

struct ManagedCatalogProfile: Codable, Identifiable, Hashable {
    var id: String
    var displayName: String
    var kind: String
    var regionCode: String?
    var endpointHost: String?
    var config: String

    private enum CodingKeys: String, CodingKey {
        case id, displayName, kind, regionCode, endpointHost, config
    }

    init(id: String, displayName: String, kind: String, regionCode: String? = nil, endpointHost: String? = nil, config: String) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.regionCode = regionCode
        self.endpointHost = endpointHost
        self.config = config
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        kind = try container.decode(String.self, forKey: .kind)
        regionCode = try container.decodeIfPresent(String.self, forKey: .regionCode)
        endpointHost = try container.decodeIfPresent(String.self, forKey: .endpointHost)
        config = try container.decode(CatalogConfigurationValue.self, forKey: .config).rawValue
    }
}

private enum CatalogConfigurationValue: Decodable {
    case string(String)
    case json(JSONValue)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .json(try container.decode(JSONValue.self))
        }
    }

    var rawValue: String {
        switch self {
        case .string(let value): return value
        case .json(let value):
            let data = (try? JSONEncoder.catalog.encode(value)) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    }
}

private indirect enum JSONValue: Codable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

private struct CatalogManifest: Codable {
    let schemaVersion: Int
    let catalogID: String
    let role: CatalogRole
    let revision: String
    let generatedAt: String
    let expiresAt: String
    let profiles: [ManagedCatalogProfile]
}

private struct SignedEnvelope: Codable {
    let payload: String
    let signature: String
}

@MainActor
final class CatalogManagerModel: ObservableObject {
    @Published var selectedRole: CatalogRole = .user
    @Published private(set) var userProfiles: [ManagedCatalogProfile] = []
    @Published private(set) var adminProfiles: [ManagedCatalogProfile] = []
    @Published var selectedProfileID: String?
    @Published private(set) var publicKey = ""
    @Published private(set) var status = "Loading current catalogs…"
    @Published private(set) var isWorking = false

    private let repository = "G5023890/Real-Ai-VPN-Catalog"
    private let rawBaseURL = URL(string: "https://raw.githubusercontent.com/G5023890/Real-Ai-VPN-Catalog/main/catalogs")!
    private let keyStore = SigningKeyStore()

    init() {
        Task { await bootstrap() }
    }

    var profiles: [ManagedCatalogProfile] {
        selectedRole == .user ? userProfiles : adminProfiles
    }

    func importConfigurations() {
        let panel = NSOpenPanel()
        panel.title = "Choose VPN configuration files for \(selectedRole.title)"
        panel.message = "Select VLESS/Xray JSON configuration files."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json, .data]
        guard panel.runModal() == .OK else { return }

        var imported: [ManagedCatalogProfile] = []
        var rejected: [String] = []
        for url in panel.urls {
            do { imported.append(try profile(from: url, role: selectedRole)) }
            catch { rejected.append(url.lastPathComponent) }
        }
        guard !imported.isEmpty else {
            status = rejected.isEmpty ? "No files selected." : "Could not read: \(rejected.joined(separator: ", "))."
            return
        }
        replaceOrAppend(imported, for: selectedRole)
        selectedProfileID = imported.last?.id
        status = "Added \(imported.count) profile(s) to \(selectedRole.title). Press Publish \(selectedRole.title) to update GitHub."
    }

    func removeSelectedProfile() {
        guard let selectedProfileID else { return }
        if selectedRole == .user { userProfiles.removeAll { $0.id == selectedProfileID } }
        else { adminProfiles.removeAll { $0.id == selectedProfileID } }
        self.selectedProfileID = nil
        status = "Profile removed locally. Press Publish \(selectedRole.title) to update GitHub."
    }

    func publishSelectedRole() {
        let role = selectedRole
        let profiles = self.profiles
        isWorking = true
        status = "Signing and publishing \(role.title) catalog…"
        Task {
            do {
                let key = try keyStore.loadOrCreate()
                publicKey = key.publicKey.rawRepresentation.base64EncodedString()
                let signed = try signedCatalog(role: role, profiles: profiles, key: key)
                try GitHubPublisher(repository: repository).upload(data: signed, path: "catalogs/\(role.remoteFileName)", message: "Catalog Manager: update \(role.title) catalog")
                status = "Published \(role.title): \(profiles.count) profile(s). Sync this category in Real Ai Router."
            } catch {
                status = "Publish failed: \(error.localizedDescription)"
            }
            isWorking = false
        }
    }

    func copyPublicKey() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(publicKey, forType: .string)
        status = "Public key copied. Paste it into Real Ai Router → Remote Catalogs before publishing with a new key."
    }

    private func bootstrap() async {
        do {
            let key = try keyStore.loadOrCreate()
            publicKey = key.publicKey.rawRepresentation.base64EncodedString()
            async let user = downloadCatalog(role: .user)
            async let admin = downloadCatalog(role: .admin)
            userProfiles = try await user
            adminProfiles = try await admin
            status = "Loaded \(userProfiles.count) User and \(adminProfiles.count) Admin profiles."
        } catch {
            status = "Created local signing key. GitHub catalogs could not be loaded: \(error.localizedDescription)"
        }
    }

    private func downloadCatalog(role: CatalogRole) async throws -> [ManagedCatalogProfile] {
        let url = rawBaseURL.appendingPathComponent(role.remoteFileName)
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CatalogManagerError.invalidRemoteCatalog }
        let envelope = try JSONDecoder().decode(SignedEnvelope.self, from: data)
        guard let payload = Data(base64Encoded: envelope.payload) else { throw CatalogManagerError.invalidRemoteCatalog }
        return try JSONDecoder().decode(CatalogManifest.self, from: payload).profiles
    }

    private func profile(from url: URL, role: CatalogRole) throws -> ManagedCatalogProfile {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogManagerError.invalidConfiguration
        }
        let displayName = (object["remarks"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (displayName?.isEmpty == false ? displayName! : url.deletingPathExtension().lastPathComponent)
        let endpoint = Self.endpointHost(in: object)
        let id = "\(role.rawValue)-\(Self.slug(name))-\(Self.shortDigest(data))"
        return ManagedCatalogProfile(
            id: id,
            displayName: name,
            kind: "VLESS Reality",
            regionCode: Self.regionCode(in: name),
            endpointHost: endpoint,
            config: String(decoding: data, as: UTF8.self)
        )
    }

    private func replaceOrAppend(_ incoming: [ManagedCatalogProfile], for role: CatalogRole) {
        var existing = role == .user ? userProfiles : adminProfiles
        for profile in incoming {
            if let index = existing.firstIndex(where: { $0.id == profile.id }) { existing[index] = profile }
            else { existing.append(profile) }
        }
        existing.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        if role == .user { userProfiles = existing } else { adminProfiles = existing }
    }

    private func signedCatalog(role: CatalogRole, profiles: [ManagedCatalogProfile], key: Curve25519.Signing.PrivateKey) throws -> Data {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let manifest = CatalogManifest(
            schemaVersion: 1,
            catalogID: "primary",
            role: role,
            revision: formatter.string(from: now),
            generatedAt: formatter.string(from: now),
            expiresAt: formatter.string(from: Calendar.current.date(byAdding: .day, value: 90, to: now)!),
            profiles: profiles
        )
        let payload = try JSONEncoder.catalog.encode(manifest)
        let signature = try key.signature(for: payload)
        return try JSONEncoder.catalog.encode(SignedEnvelope(payload: payload.base64EncodedString(), signature: signature.base64EncodedString()))
    }

    private static func endpointHost(in object: [String: Any]) -> String? {
        guard let outbounds = object["outbounds"] as? [[String: Any]] else { return nil }
        for outbound in outbounds where outbound["protocol"] as? String == "vless" {
            let settings = outbound["settings"] as? [String: Any]
            let vnext = settings?["vnext"] as? [[String: Any]]
            if let address = vnext?.first?["address"] as? String { return address }
        }
        return nil
    }

    private static func regionCode(in name: String) -> String? {
        let flagScalars = name.unicodeScalars.filter { (0x1F1E6...0x1F1FF).contains($0.value) }
        guard flagScalars.count >= 2 else { return nil }
        return String(flagScalars.prefix(2).compactMap { UnicodeScalar($0.value - 0x1F1E6 + 65) }.map(Character.init))
    }

    private static func slug(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let raw = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character(String($0).lowercased()) : "-" }
        return String(raw).split(separator: "-").joined(separator: "-").prefix(36).description
    }

    private static func shortDigest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(5).map { String(format: "%02x", $0) }.joined()
    }
}

private enum CatalogManagerError: LocalizedError {
    case invalidRemoteCatalog
    case invalidConfiguration
    case ghNotAuthenticated
    case ghFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRemoteCatalog: return "The signed catalog could not be read."
        case .invalidConfiguration: return "This file is not a VLESS/Xray JSON configuration."
        case .ghNotAuthenticated: return "GitHub CLI is not authorized. Run: gh auth login"
        case .ghFailed(let message): return message
        }
    }
}

private struct SigningKeyStore {
    private let service = "com.codex.RealAiVPN.CatalogManager"
    private let account = "ed25519-signing-private-key"

    func loadOrCreate() throws -> Curve25519.Signing.PrivateKey {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        guard status == errSecItemNotFound else { throw CatalogManagerError.ghFailed("Could not read local signing key (\(status)).") }
        let key = Curve25519.Signing.PrivateKey()
        query.removeValue(forKey: kSecReturnData as String)
        query.removeValue(forKey: kSecMatchLimit as String)
        query[kSecValueData as String] = key.rawRepresentation
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CatalogManagerError.ghFailed("Could not save local signing key (\(addStatus)).") }
        return key
    }
}

private struct GitHubPublisher {
    let repository: String

    func upload(data: Data, path: String, message: String) throws {
        let sha = try? run(["api", "repos/\(repository)/contents/\(path)", "--jq", ".sha"]).trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = ["api", "--method", "PUT", "repos/\(repository)/contents/\(path)", "-f", "message=\(message)", "-f", "content=\(data.base64EncodedString())"]
        if let sha, !sha.isEmpty { arguments += ["-f", "sha=\(sha)"] }
        _ = try run(arguments)
    }

    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CatalogManagerError.ghNotAuthenticated
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { throw CatalogManagerError.ghNotAuthenticated }
        process.waitUntilExit()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            if error.localizedCaseInsensitiveContains("authentication") { throw CatalogManagerError.ghNotAuthenticated }
            throw CatalogManagerError.ghFailed(error.isEmpty ? "GitHub upload failed." : error)
        }
        return output
    }
}

private struct CatalogManagerView: View {
    @ObservedObject var model: CatalogManagerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Catalog Manager").font(.largeTitle.bold())
                    Text("Import VLESS configuration files, organize them into User or Admin, then sign and publish.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Text("Ed25519 public key").font(.caption).foregroundStyle(.secondary)
                    Text(model.publicKey.isEmpty ? "Creating…" : model.publicKey)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2)
                        .frame(width: 340, alignment: .trailing)
                    Button("Copy public key", action: model.copyPublicKey).disabled(model.publicKey.isEmpty)
                }
            }

            Picker("Category", selection: $model.selectedRole) {
                ForEach(CatalogRole.allCases) { role in Text(role.title).tag(role) }
            }
            .pickerStyle(.segmented)
            .frame(width: 230)

            Table(model.profiles, selection: $model.selectedProfileID) {
                TableColumn("Name", value: \.displayName)
                TableColumn("Region") { Text($0.regionCode ?? "—") }.width(70)
                TableColumn("Endpoint") { Text($0.endpointHost ?? "—") }.width(min: 190, ideal: 260)
                TableColumn("ID") { Text($0.id).font(.system(.caption, design: .monospaced)) }.width(min: 190, ideal: 260)
            }

            HStack {
                Button("Import configuration files…", action: model.importConfigurations)
                Button("Remove selected", role: .destructive, action: model.removeSelectedProfile)
                    .disabled(model.selectedProfileID == nil)
                Spacer()
                Button("Publish \(model.selectedRole.title)") { model.publishSelectedRole() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking)
            }

            Text(model.status)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("The signing key is stored only in this Mac’s Keychain. Before the first publish, copy the displayed public key into Real Ai Router → VPN Profiles → Remote Catalogs. Publishing changes only the selected signed catalog; manual VPN profiles are never changed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(28)
    }
}

private extension JSONEncoder {
    static var catalog: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
