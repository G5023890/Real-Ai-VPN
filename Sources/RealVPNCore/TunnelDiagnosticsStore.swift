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

    public init(suiteName: String = Self.suiteName) {
        self.suiteName = suiteName
    }

    public func save(_ snapshot: TunnelDiagnosticSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot),
              let defaults = UserDefaults(suiteName: suiteName) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    public func load() -> TunnelDiagnosticSnapshot? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(TunnelDiagnosticSnapshot.self, from: data)
    }
}
