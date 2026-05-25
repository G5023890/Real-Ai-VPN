import Foundation

public struct RegionCode: Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue.uppercased()
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var description: String {
        rawValue
    }
}

public enum NetworkKind: String, Codable, Sendable {
    case wifi
    case cellular
    case wired
    case unknown
}

public enum VPNProtocolKind: String, Codable, Sendable {
    case amneziaWG
    case wireGuard
    case xray
    case openVPN
    case unknown
}

public enum ServerHealthState: String, Codable, Sendable {
    case healthy
    case degraded
    case unhealthy
}

public struct SmartVPNServer: Hashable, Codable, Sendable {
    public let id: String
    public var region: RegionCode
    public var displayName: String
    public var protocolKind: VPNProtocolKind
    public var lastLatencyMilliseconds: Double?
    public var healthState: ServerHealthState

    public init(
        id: String,
        region: RegionCode,
        displayName: String,
        protocolKind: VPNProtocolKind,
        lastLatencyMilliseconds: Double? = nil,
        healthState: ServerHealthState = .healthy
    ) {
        self.id = id
        self.region = region
        self.displayName = displayName
        self.protocolKind = protocolKind
        self.lastLatencyMilliseconds = lastLatencyMilliseconds
        self.healthState = healthState
    }
}

public struct ServerSelectionContext: Hashable, Codable, Sendable {
    public var currentRegion: RegionCode
    public var homeRegion: RegionCode
    public var networkKind: NetworkKind
    public var providerASN: String?
    public var hourOfDay: Int
    public var previousServerID: String?

    public init(
        currentRegion: RegionCode,
        homeRegion: RegionCode,
        networkKind: NetworkKind,
        providerASN: String? = nil,
        hourOfDay: Int,
        previousServerID: String? = nil
    ) {
        self.currentRegion = currentRegion
        self.homeRegion = homeRegion
        self.networkKind = networkKind
        self.providerASN = providerASN
        self.hourOfDay = min(max(hourOfDay, 0), 23)
        self.previousServerID = previousServerID
    }
}

public struct ServerQualitySample: Hashable, Codable, Sendable {
    public var serverID: String
    public var region: RegionCode
    public var networkKind: NetworkKind
    public var providerASNHash: String?
    public var latencyMilliseconds: Double
    public var packetLoss: Double
    public var handshakeMilliseconds: Double
    public var recentFailureCount: Int
    public var timestamp: Date

    public init(
        serverID: String,
        region: RegionCode,
        networkKind: NetworkKind,
        providerASNHash: String? = nil,
        latencyMilliseconds: Double,
        packetLoss: Double,
        handshakeMilliseconds: Double,
        recentFailureCount: Int,
        timestamp: Date = Date()
    ) {
        self.serverID = serverID
        self.region = region
        self.networkKind = networkKind
        self.providerASNHash = providerASNHash
        self.latencyMilliseconds = max(0, latencyMilliseconds)
        self.packetLoss = min(max(packetLoss, 0), 1)
        self.handshakeMilliseconds = max(0, handshakeMilliseconds)
        self.recentFailureCount = max(0, recentFailureCount)
        self.timestamp = timestamp
    }
}

public enum ProbeTargetKind: String, Codable, Sendable {
    case vpnServer
    case vpnProtectedEndpoint
    case directEndpoint
    case dnsResolver
}

public enum ProbeMethod: String, Codable, Sendable {
    case icmpPing
    case tcpConnect
    case dnsQuery
    case httpHead
    case tunnelHandshake
}

public struct ConnectivityProbeResult: Hashable, Codable, Sendable {
    public var targetID: String
    public var targetKind: ProbeTargetKind
    public var serverID: String?
    public var region: RegionCode?
    public var method: ProbeMethod
    public var succeeded: Bool
    public var latencyMilliseconds: Double?
    public var packetLoss: Double
    public var timestamp: Date

    public init(
        targetID: String,
        targetKind: ProbeTargetKind,
        serverID: String? = nil,
        region: RegionCode? = nil,
        method: ProbeMethod,
        succeeded: Bool,
        latencyMilliseconds: Double? = nil,
        packetLoss: Double = 0,
        timestamp: Date = Date()
    ) {
        self.targetID = targetID
        self.targetKind = targetKind
        self.serverID = serverID
        self.region = region
        self.method = method
        self.succeeded = succeeded
        self.latencyMilliseconds = latencyMilliseconds.map { max(0, $0) }
        self.packetLoss = min(max(packetLoss, 0), 1)
        self.timestamp = timestamp
    }
}

public enum PathHealthState: String, Codable, Sendable {
    case healthy
    case degraded
    case stalled
    case down
}

public struct PathHealthReport: Hashable, Codable, Sendable {
    public var state: PathHealthState
    public var successRate: Double
    public var averageLatencyMilliseconds: Double?
    public var averagePacketLoss: Double
    public var consecutiveFailures: Int
    public var reason: String

    public init(
        state: PathHealthState,
        successRate: Double,
        averageLatencyMilliseconds: Double?,
        averagePacketLoss: Double,
        consecutiveFailures: Int,
        reason: String
    ) {
        self.state = state
        self.successRate = min(max(successRate, 0), 1)
        self.averageLatencyMilliseconds = averageLatencyMilliseconds
        self.averagePacketLoss = min(max(averagePacketLoss, 0), 1)
        self.consecutiveFailures = max(0, consecutiveFailures)
        self.reason = reason
    }
}

public enum VPNParameterAdjustment: Hashable, Codable, Sendable {
    case reduceMTU
    case rotatePort
    case refreshDNS
    case rehandshake
}

public enum RecoveryAction: Hashable, Codable, Sendable {
    case keepCurrent(reason: String)
    case refreshDirectDNS(reason: String)
    case reconnect(serverID: String, reason: String)
    case switchServer(from: String?, to: String, reason: String)
    case adjustParameters(serverID: String, adjustments: [VPNParameterAdjustment], reason: String)
    case askUser(reason: String)
}

public struct PreventiveHealthAssessment: Hashable, Codable, Sendable {
    public var directPath: PathHealthReport
    public var vpnPath: PathHealthReport
    public var recommendedAction: RecoveryAction
    public var rankedServers: [RankedServer]

    public init(
        directPath: PathHealthReport,
        vpnPath: PathHealthReport,
        recommendedAction: RecoveryAction,
        rankedServers: [RankedServer] = []
    ) {
        self.directPath = directPath
        self.vpnPath = vpnPath
        self.recommendedAction = recommendedAction
        self.rankedServers = rankedServers
    }
}

public struct RankedServer: Hashable, Codable, Sendable {
    public var server: SmartVPNServer
    public var score: Double
    public var confidence: Double
    public var reason: String

    public init(server: SmartVPNServer, score: Double, confidence: Double, reason: String) {
        self.server = server
        self.score = min(max(score, 0), 1)
        self.confidence = min(max(confidence, 0), 1)
        self.reason = reason
    }
}

public enum DestinationRegion: Hashable, Codable, Sendable {
    case current
    case home
    case foreign
    case explicit(RegionCode)
}

public enum HardRouteDecision: Hashable, Codable, Sendable {
    case directProviderDNS(reason: String)
    case homeVPN(region: RegionCode, reason: String)
    case noHardRule
}

public struct RouteDecision: Hashable, Codable, Sendable {
    public enum Action: Hashable, Codable, Sendable {
        case directProviderDNS
        case vpn(serverID: String, region: RegionCode)
        case ask(reason: String)
    }

    public var action: Action
    public var source: String
    public var rankedServers: [RankedServer]

    public init(action: Action, source: String, rankedServers: [RankedServer] = []) {
        self.action = action
        self.source = source
        self.rankedServers = rankedServers
    }
}

public protocol ServerQualityHistoryStore: Sendable {
    func samples(for serverID: String) -> [ServerQualitySample]
    func record(_ sample: ServerQualitySample)
}

public final class InMemoryServerQualityHistoryStore: ServerQualityHistoryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var samplesByServerID: [String: [ServerQualitySample]] = [:]
    private let maxSamplesPerServer: Int

    public init(maxSamplesPerServer: Int = 64) {
        self.maxSamplesPerServer = max(1, maxSamplesPerServer)
    }

    public func samples(for serverID: String) -> [ServerQualitySample] {
        lock.withLock {
            samplesByServerID[serverID] ?? []
        }
    }

    public func record(_ sample: ServerQualitySample) {
        lock.withLock {
            var samples = samplesByServerID[sample.serverID] ?? []
            samples.append(sample)
            if samples.count > maxSamplesPerServer {
                samples.removeFirst(samples.count - maxSamplesPerServer)
            }
            samplesByServerID[sample.serverID] = samples
        }
    }
}

public protocol ServerScoring {
    func rank(
        servers: [SmartVPNServer],
        context: ServerSelectionContext,
        historyStore: ServerQualityHistoryStore
    ) -> [RankedServer]
}

public struct HeuristicServerScorer: ServerScoring, Sendable {
    public init() {}

    public func rank(
        servers: [SmartVPNServer],
        context: ServerSelectionContext,
        historyStore: ServerQualityHistoryStore
    ) -> [RankedServer] {
        servers
            .filter { $0.healthState != .unhealthy }
            .map { server in
                rank(server: server, context: context, historyStore: historyStore)
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.server.id < rhs.server.id
                }

                return lhs.score > rhs.score
            }
    }

    private func rank(
        server: SmartVPNServer,
        context: ServerSelectionContext,
        historyStore: ServerQualityHistoryStore
    ) -> RankedServer {
        let samples = historyStore.samples(for: server.id)
        let recentSamples = Array(samples.suffix(12))
        let averageLatency = average(recentSamples.map(\.latencyMilliseconds)) ?? server.lastLatencyMilliseconds ?? 250
        let averageHandshake = average(recentSamples.map(\.handshakeMilliseconds)) ?? 350
        let averagePacketLoss = average(recentSamples.map(\.packetLoss)) ?? 0
        let averageFailures = average(recentSamples.map { Double($0.recentFailureCount) }) ?? 0

        var score = 1.0
        score -= min(averageLatency / 900, 0.45)
        score -= min(averageHandshake / 1_500, 0.2)
        score -= min(averagePacketLoss * 1.7, 0.25)
        score -= min(averageFailures * 0.07, 0.25)

        if server.healthState == .degraded {
            score -= 0.12
        }

        if server.id == context.previousServerID {
            score += 0.04
        }

        if context.networkKind == .cellular {
            score -= min(averageHandshake / 4_000, 0.04)
        }

        let confidence = min(0.35 + Double(recentSamples.count) / 12 * 0.55, 0.9)
        let reason = "latency=\(Int(averageLatency))ms handshake=\(Int(averageHandshake))ms loss=\(Int(averagePacketLoss * 100))% samples=\(recentSamples.count)"

        return RankedServer(server: server, score: score, confidence: confidence, reason: reason)
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }

        return values.reduce(0, +) / Double(values.count)
    }
}

public struct SmartServerSelector {
    private let scorer: ServerScoring
    private let historyStore: ServerQualityHistoryStore

    public init(
        scorer: ServerScoring = HeuristicServerScorer(),
        historyStore: ServerQualityHistoryStore = InMemoryServerQualityHistoryStore()
    ) {
        self.scorer = scorer
        self.historyStore = historyStore
    }

    public func record(_ sample: ServerQualitySample) {
        historyStore.record(sample)
    }

    public func decideRoute(
        destinationRegion: DestinationRegion,
        context: ServerSelectionContext,
        servers: [SmartVPNServer]
    ) -> RouteDecision {
        switch hardRule(for: destinationRegion, context: context) {
        case .directProviderDNS(let reason):
            return RouteDecision(action: .directProviderDNS, source: reason)
        case .homeVPN(let region, let reason):
            return selectServer(in: region, context: context, servers: servers, source: reason)
        case .noHardRule:
            return selectFastestVPN(context: context, servers: servers)
        }
    }

    public func rankedServers(
        context: ServerSelectionContext,
        servers: [SmartVPNServer]
    ) -> [RankedServer] {
        scorer.rank(servers: servers, context: context, historyStore: historyStore)
    }

    private func hardRule(
        for destinationRegion: DestinationRegion,
        context: ServerSelectionContext
    ) -> HardRouteDecision {
        switch destinationRegion {
        case .current:
            return .directProviderDNS(reason: "current-region-direct-provider-dns")
        case .home:
            return .homeVPN(region: context.homeRegion, reason: "home-region-vpn")
        case .explicit(let region) where region == context.currentRegion:
            return .directProviderDNS(reason: "explicit-current-region-direct-provider-dns")
        case .explicit(let region) where region == context.homeRegion:
            return .homeVPN(region: context.homeRegion, reason: "explicit-home-region-vpn")
        case .foreign, .explicit:
            return .noHardRule
        }
    }

    private func selectServer(
        in region: RegionCode,
        context: ServerSelectionContext,
        servers: [SmartVPNServer],
        source: String
    ) -> RouteDecision {
        let regionalServers = servers.filter { $0.region == region }
        let ranked = scorer.rank(servers: regionalServers, context: context, historyStore: historyStore)

        guard let selected = ranked.first else {
            return RouteDecision(action: .ask(reason: "no-healthy-server-for-\(region.rawValue)"), source: source)
        }

        return RouteDecision(
            action: .vpn(serverID: selected.server.id, region: selected.server.region),
            source: source,
            rankedServers: ranked
        )
    }

    private func selectFastestVPN(
        context: ServerSelectionContext,
        servers: [SmartVPNServer]
    ) -> RouteDecision {
        let ranked = scorer.rank(servers: servers, context: context, historyStore: historyStore)

        guard let selected = ranked.first else {
            return RouteDecision(action: .ask(reason: "no-healthy-vpn-server"), source: "fastest-vpn-fallback")
        }

        return RouteDecision(
            action: .vpn(serverID: selected.server.id, region: selected.server.region),
            source: "fastest-vpn-heuristic",
            rankedServers: ranked
        )
    }
}

public struct PreventiveVPNHealthMonitor {
    private let selector: SmartServerSelector

    public init(selector: SmartServerSelector = SmartServerSelector()) {
        self.selector = selector
    }

    public func assess(
        probes: [ConnectivityProbeResult],
        activeServerID: String?,
        context: ServerSelectionContext,
        servers: [SmartVPNServer]
    ) -> PreventiveHealthAssessment {
        let directReport = report(for: probes.filter { $0.targetKind == .directEndpoint || $0.targetKind == .dnsResolver })
        let vpnReport = report(for: probes.filter { $0.targetKind == .vpnServer || $0.targetKind == .vpnProtectedEndpoint })
        let ranked = selector.rankedServers(context: context, servers: servers)
        let action = recoveryAction(
            directReport: directReport,
            vpnReport: vpnReport,
            activeServerID: activeServerID,
            rankedServers: ranked
        )

        return PreventiveHealthAssessment(
            directPath: directReport,
            vpnPath: vpnReport,
            recommendedAction: action,
            rankedServers: ranked
        )
    }

    private func recoveryAction(
        directReport: PathHealthReport,
        vpnReport: PathHealthReport,
        activeServerID: String?,
        rankedServers: [RankedServer]
    ) -> RecoveryAction {
        if directReport.state == .down {
            return .askUser(reason: "provider-path-down")
        }

        if directReport.state == .degraded {
            return .refreshDirectDNS(reason: "provider-dns-or-direct-path-degraded")
        }

        switch vpnReport.state {
        case .healthy:
            return .keepCurrent(reason: "vpn-path-healthy")
        case .degraded:
            if let activeServerID {
                return .adjustParameters(
                    serverID: activeServerID,
                    adjustments: [.rehandshake, .refreshDNS],
                    reason: "vpn-path-degraded"
                )
            }

            return .askUser(reason: "vpn-path-degraded-without-active-server")
        case .stalled, .down:
            if let replacement = rankedServers.first(where: { $0.server.id != activeServerID }) {
                return .switchServer(
                    from: activeServerID,
                    to: replacement.server.id,
                    reason: "vpn-path-\(vpnReport.state.rawValue)"
                )
            }

            if let activeServerID {
                return .reconnect(serverID: activeServerID, reason: "vpn-path-\(vpnReport.state.rawValue)-no-replacement")
            }

            return .askUser(reason: "vpn-path-\(vpnReport.state.rawValue)-no-server")
        }
    }

    private func report(for probes: [ConnectivityProbeResult]) -> PathHealthReport {
        guard !probes.isEmpty else {
            return PathHealthReport(
                state: .down,
                successRate: 0,
                averageLatencyMilliseconds: nil,
                averagePacketLoss: 1,
                consecutiveFailures: 0,
                reason: "no-probes"
            )
        }

        let recent = Array(probes.sorted { $0.timestamp < $1.timestamp }.suffix(8))
        let successes = recent.filter(\.succeeded)
        let successRate = Double(successes.count) / Double(recent.count)
        let averageLatency = average(successes.compactMap(\.latencyMilliseconds))
        let averagePacketLoss = average(recent.map(\.packetLoss)) ?? 0
        let consecutiveFailures = recent.reversed().prefix { !$0.succeeded }.count
        let state: PathHealthState
        let reason: String

        if consecutiveFailures >= 3 || successRate == 0 {
            state = .down
            reason = "consecutive-failures=\(consecutiveFailures)"
        } else if consecutiveFailures >= 2 || successRate < 0.5 {
            state = .stalled
            reason = "stalled-success-rate=\(String(format: "%.2f", successRate))"
        } else if successRate < 0.85 || averagePacketLoss > 0.08 || (averageLatency ?? 0) > 1_200 {
            state = .degraded
            reason = "degraded-success-rate=\(String(format: "%.2f", successRate))"
        } else {
            state = .healthy
            reason = "healthy"
        }

        return PathHealthReport(
            state: state,
            successRate: successRate,
            averageLatencyMilliseconds: averageLatency,
            averagePacketLoss: averagePacketLoss,
            consecutiveFailures: consecutiveFailures,
            reason: reason
        )
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }

        return values.reduce(0, +) / Double(values.count)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
