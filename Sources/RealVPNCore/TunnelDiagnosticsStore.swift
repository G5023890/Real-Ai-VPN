import Foundation

public struct TunnelDiagnosticSnapshot: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var providerBundleIdentifier: String
    public var stage: String
    public var message: String

    public init(
        timestamp: Date = Date(),
        providerBundleIdentifier: String,
        stage: String,
        message: String
    ) {
        self.timestamp = timestamp
        self.providerBundleIdentifier = providerBundleIdentifier
        self.stage = stage
        self.message = message
    }
}

public struct TunnelDiagnosticsStore: Sendable {
    public static let suiteName = "group.com.codex.RealAiVPN.iOS"

    private let suiteName: String
    private let key = "real_ai_vpn.last_tunnel_diagnostic"
    private let sharedFileName = "real-ai-vpn-last-tunnel-diagnostic.json"
    private let fallbackFileURL = URL(fileURLWithPath: "/tmp/real-ai-vpn-last-tunnel-diagnostic.json")

    public init(suiteName: String = Self.suiteName) {
        self.suiteName = suiteName
    }

    public func save(_ snapshot: TunnelDiagnosticSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        if usesSharedDefaults, let defaults = UserDefaults(suiteName: suiteName) {
            defaults.set(data, forKey: key)
            defaults.synchronize()
        }
        if let sharedFileURL {
            try? data.write(to: sharedFileURL, options: [.atomic])
        }
        try? data.write(to: fallbackFileURL, options: [.atomic])
    }

    public func load() -> TunnelDiagnosticSnapshot? {
        if usesSharedDefaults,
           let defaults = UserDefaults(suiteName: suiteName),
           let data = defaults.data(forKey: key),
           let snapshot = try? JSONDecoder().decode(TunnelDiagnosticSnapshot.self, from: data) {
            return snapshot
        }
        if let sharedFileURL,
           let data = try? Data(contentsOf: sharedFileURL),
           let snapshot = try? JSONDecoder().decode(TunnelDiagnosticSnapshot.self, from: data) {
            return snapshot
        }
        guard let data = try? Data(contentsOf: fallbackFileURL) else {
            return nil
        }
        return try? JSONDecoder().decode(TunnelDiagnosticSnapshot.self, from: data)
    }

    private var sharedFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: suiteName)?
            .appendingPathComponent(sharedFileName, isDirectory: false)
    }

    private var usesSharedDefaults: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }
}
