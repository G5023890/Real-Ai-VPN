import Foundation

public enum TunnelTrafficSource: String, Codable, Sendable {
    case wireGuardRuntime
    case singBoxStatus
    case networkInterface
    case unavailable
}

public struct TunnelTrafficStats: Codable, Equatable, Sendable {
    public var profileID: String
    public var `protocol`: String
    public var startedAt: Date
    public var duration: TimeInterval
    public var rxBytes: UInt64?
    public var txBytes: UInt64?
    public var rxPackets: UInt64?
    public var txPackets: UInt64?
    public var lastUpdatedAt: Date
    public var source: TunnelTrafficSource

    public init(
        profileID: String,
        protocol: String,
        startedAt: Date,
        duration: TimeInterval,
        rxBytes: UInt64?,
        txBytes: UInt64?,
        rxPackets: UInt64? = nil,
        txPackets: UInt64? = nil,
        lastUpdatedAt: Date = Date(),
        source: TunnelTrafficSource
    ) {
        self.profileID = profileID
        self.protocol = `protocol`
        self.startedAt = startedAt
        self.duration = max(0, duration)
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.rxPackets = rxPackets
        self.txPackets = txPackets
        self.lastUpdatedAt = lastUpdatedAt
        self.source = source
    }

    public var totalBytes: UInt64? {
        switch (rxBytes, txBytes) {
        case (.some(let rx), .some(let tx)):
            return rx + tx
        case (.some(let rx), .none):
            return rx
        case (.none, .some(let tx)):
            return tx
        case (.none, .none):
            return nil
        }
    }

    public var trafficObserved: Bool? {
        totalBytes.map { $0 > 0 }
    }
}

public struct TunnelTrafficStatsStore: Sendable {
    public static let suiteName = "group.com.codex.RealAiVPN.iOS"

    private let suiteName: String
    private let key = "real_ai_vpn.tunnel_traffic_stats"
    private let sharedFileName = "real-ai-vpn-tunnel-traffic-stats.json"
    private let fallbackFileURL = URL(fileURLWithPath: "/tmp/real-ai-vpn-tunnel-traffic-stats.json")

    public init(suiteName: String = Self.suiteName) {
        self.suiteName = suiteName
    }

    public func save(_ stats: TunnelTrafficStats) {
        guard let data = try? JSONEncoder().encode(stats) else {
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

    public func load() -> TunnelTrafficStats? {
        if usesSharedDefaults,
           let defaults = UserDefaults(suiteName: suiteName),
           let data = defaults.data(forKey: key),
           let stats = try? JSONDecoder().decode(TunnelTrafficStats.self, from: data) {
            return stats
        }
        if let sharedFileURL,
           let data = try? Data(contentsOf: sharedFileURL),
           let stats = try? JSONDecoder().decode(TunnelTrafficStats.self, from: data) {
            return stats
        }
        guard let data = try? Data(contentsOf: fallbackFileURL) else {
            return nil
        }
        return try? JSONDecoder().decode(TunnelTrafficStats.self, from: data)
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
