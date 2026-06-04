import Foundation
#if canImport(CoreML)
import CoreML
#endif

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
    case singBox
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
    case httpGet
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

public struct ProbeReliabilitySummary: Hashable, Codable, Sendable {
    public var targetID: String
    public var targetKind: ProbeTargetKind
    public var serverID: String?
    public var method: ProbeMethod
    public var sampleCount: Int
    public var successRate: Double
    public var averageLatencyMilliseconds: Double?
    public var reliabilityScore: Double
    public var lastSeen: Date?

    public init(
        targetID: String,
        targetKind: ProbeTargetKind,
        serverID: String?,
        method: ProbeMethod,
        sampleCount: Int,
        successRate: Double,
        averageLatencyMilliseconds: Double?,
        reliabilityScore: Double,
        lastSeen: Date?
    ) {
        self.targetID = targetID
        self.targetKind = targetKind
        self.serverID = serverID
        self.method = method
        self.sampleCount = max(0, sampleCount)
        self.successRate = min(max(successRate, 0), 1)
        self.averageLatencyMilliseconds = averageLatencyMilliseconds
        self.reliabilityScore = min(max(reliabilityScore, 0), 1)
        self.lastSeen = lastSeen
    }
}

public struct ProbeReliabilityAnalyzer: Sendable {
    public var minimumSamplesForFiltering: Int
    public var minimumReliabilityScore: Double

    public init(minimumSamplesForFiltering: Int = 6, minimumReliabilityScore: Double = 0.45) {
        self.minimumSamplesForFiltering = max(1, minimumSamplesForFiltering)
        self.minimumReliabilityScore = min(max(minimumReliabilityScore, 0), 1)
    }

    public func summaries(from history: [ConnectivityProbeResult]) -> [ProbeReliabilitySummary] {
        Dictionary(grouping: history, by: ProbeReliabilityKey.init)
            .map { key, samples in summary(for: key, samples: samples) }
            .sorted {
                if $0.reliabilityScore != $1.reliabilityScore {
                    return $0.reliabilityScore > $1.reliabilityScore
                }
                return $0.targetID < $1.targetID
            }
    }

    public func summaries(
        from history: [ConnectivityProbeResult],
        serverID: String?,
        targetKind: ProbeTargetKind? = nil
    ) -> [ProbeReliabilitySummary] {
        summaries(from: history).filter { summary in
            summary.serverID == serverID && (targetKind == nil || summary.targetKind == targetKind)
        }
    }

    public func filteredCurrentProbes(
        _ probes: [ConnectivityProbeResult],
        using history: [ConnectivityProbeResult]
    ) -> [ConnectivityProbeResult] {
        guard !probes.isEmpty, !history.isEmpty else {
            return probes
        }

        let summariesByKey = Dictionary(uniqueKeysWithValues: summaries(from: history).map { (ProbeReliabilityKey($0), $0) })
        let filtered = probes.filter { probe in
            guard let summary = summariesByKey[ProbeReliabilityKey(probe)] else {
                return true
            }

            if probe.succeeded {
                return true
            }

            return summary.sampleCount < minimumSamplesForFiltering || summary.reliabilityScore >= minimumReliabilityScore
        }

        return filtered.isEmpty ? probes : filtered
    }

    public func bestSummary(
        from history: [ConnectivityProbeResult],
        serverID: String?,
        targetKind: ProbeTargetKind? = nil
    ) -> ProbeReliabilitySummary? {
        summaries(from: history, serverID: serverID, targetKind: targetKind).first
    }

    private func summary(for key: ProbeReliabilityKey, samples: [ConnectivityProbeResult]) -> ProbeReliabilitySummary {
        let recent = Array(samples.sorted { $0.timestamp < $1.timestamp }.suffix(60))
        let successes = recent.filter(\.succeeded)
        let successRate = recent.isEmpty ? 0 : Double(successes.count) / Double(recent.count)
        let averageLatency = average(successes.compactMap(\.latencyMilliseconds))
        let latencyScore: Double
        if let averageLatency {
            latencyScore = max(0, min(1, 1 - (averageLatency / 3_000)))
        } else {
            latencyScore = successRate > 0 ? 0.5 : 0
        }

        let sampleConfidence = min(1, Double(recent.count) / Double(minimumSamplesForFiltering))
        let reliabilityScore = ((successRate * 0.8) + (latencyScore * 0.2)) * sampleConfidence

        return ProbeReliabilitySummary(
            targetID: key.targetID,
            targetKind: key.targetKind,
            serverID: key.serverID,
            method: key.method,
            sampleCount: recent.count,
            successRate: successRate,
            averageLatencyMilliseconds: averageLatency,
            reliabilityScore: reliabilityScore,
            lastSeen: recent.last?.timestamp
        )
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }

        return values.reduce(0, +) / Double(values.count)
    }
}

private struct ProbeReliabilityKey: Hashable {
    var targetID: String
    var targetKind: ProbeTargetKind
    var serverID: String?
    var method: ProbeMethod

    init(_ probe: ConnectivityProbeResult) {
        targetID = probe.targetID
        targetKind = probe.targetKind
        serverID = probe.serverID
        method = probe.method
    }

    init(_ summary: ProbeReliabilitySummary) {
        targetID = summary.targetID
        targetKind = summary.targetKind
        serverID = summary.serverID
        method = summary.method
    }
}

public enum PathHealthState: String, Codable, Sendable {
    case healthy
    case degradedSoft
    case degradedHard
    case stalled
    case down
    case connectedButUnusable

    public var isSwitchEligible: Bool {
        switch self {
        case .stalled, .down, .connectedButUnusable:
            return true
        case .healthy, .degradedSoft, .degradedHard:
            return false
        }
    }
}

public struct PathHealthReport: Hashable, Codable, Sendable {
    public var state: PathHealthState
    public var healthScore: Double
    public var successRate: Double
    public var averageLatencyMilliseconds: Double?
    public var averagePacketLoss: Double
    public var consecutiveFailures: Int
    public var reason: String

    public init(
        state: PathHealthState,
        healthScore: Double,
        successRate: Double,
        averageLatencyMilliseconds: Double?,
        averagePacketLoss: Double,
        consecutiveFailures: Int,
        reason: String
    ) {
        self.state = state
        self.healthScore = min(max(healthScore, 0), 1)
        self.successRate = min(max(successRate, 0), 1)
        self.averageLatencyMilliseconds = averageLatencyMilliseconds
        self.averagePacketLoss = min(max(averagePacketLoss, 0), 1)
        self.consecutiveFailures = max(0, consecutiveFailures)
        self.reason = reason
    }
}

public enum PathProbeTrust: String, Codable, Sendable {
    case trusted
    case untrustedWhileVPNActive

    public var isTrusted: Bool {
        self == .trusted
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

    public var logName: String {
        switch self {
        case .keepCurrent:
            return "keepCurrent"
        case .refreshDirectDNS:
            return "refreshDirectDNS"
        case .reconnect:
            return "reconnect"
        case .switchServer:
            return "switchServer"
        case .adjustParameters:
            return "adjustParameters"
        case .askUser:
            return "askUser"
        }
    }
}

public struct PreventiveHealthAssessment: Hashable, Codable, Sendable {
    public var directPath: PathHealthReport
    public var directPathTrust: PathProbeTrust
    public var vpnPath: PathHealthReport
    public var recommendedAction: RecoveryAction
    public var rankedServers: [RankedServer]
    public var decisionLog: String

    public init(
        directPath: PathHealthReport,
        directPathTrust: PathProbeTrust = .trusted,
        vpnPath: PathHealthReport,
        recommendedAction: RecoveryAction,
        rankedServers: [RankedServer] = [],
        decisionLog: String = ""
    ) {
        self.directPath = directPath
        self.directPathTrust = directPathTrust
        self.vpnPath = vpnPath
        self.recommendedAction = recommendedAction
        self.rankedServers = rankedServers
        self.decisionLog = decisionLog
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

public struct CoreMLServerScorer: ServerScoring {
    private let fallback: any ServerScoring
    #if canImport(CoreML)
    private let model: MLModel?
    #endif

    public init(
        modelURL: URL? = nil,
        fallback: any ServerScoring = HeuristicServerScorer()
    ) {
        self.fallback = fallback
        #if canImport(CoreML)
        if let modelURL {
            self.model = try? MLModel(contentsOf: modelURL)
        } else {
            self.model = nil
        }
        #endif
    }

    public func rank(
        servers: [SmartVPNServer],
        context: ServerSelectionContext,
        historyStore: ServerQualityHistoryStore
    ) -> [RankedServer] {
        #if canImport(CoreML)
        guard let model else {
            return fallback.rank(servers: servers, context: context, historyStore: historyStore)
        }

        let ranked = servers
            .filter { $0.healthState != .unhealthy }
            .compactMap { server -> RankedServer? in
                guard let score = predictionScore(
                    for: server,
                    context: context,
                    historyStore: historyStore,
                    model: model
                ) else {
                    return nil
                }

                return RankedServer(
                    server: server,
                    score: score,
                    confidence: confidence(for: server.id, historyStore: historyStore),
                    reason: "coreml-score=\(String(format: "%.2f", score))"
                )
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.server.id < rhs.server.id
                }

                return lhs.score > rhs.score
            }

        return ranked.isEmpty ? fallback.rank(servers: servers, context: context, historyStore: historyStore) : ranked
        #else
        return fallback.rank(servers: servers, context: context, historyStore: historyStore)
        #endif
    }

    #if canImport(CoreML)
    private func predictionScore(
        for server: SmartVPNServer,
        context: ServerSelectionContext,
        historyStore: ServerQualityHistoryStore,
        model: MLModel
    ) -> Double? {
        let recentSamples = Array(historyStore.samples(for: server.id).suffix(12))
        let averageLatency = average(recentSamples.map(\.latencyMilliseconds)) ?? server.lastLatencyMilliseconds ?? 250
        let averageHandshake = average(recentSamples.map(\.handshakeMilliseconds)) ?? 350
        let averagePacketLoss = average(recentSamples.map(\.packetLoss)) ?? 0
        let recentFailures = average(recentSamples.map { Double($0.recentFailureCount) }) ?? 0
        let healthScore = approximateHealthScore(
            latencyMilliseconds: averageLatency,
            packetLoss: averagePacketLoss,
            recentFailures: recentFailures
        )

        let features: [String: MLFeatureValue] = [
            "currentRegion": MLFeatureValue(string: context.currentRegion.rawValue),
            "homeRegion": MLFeatureValue(string: context.homeRegion.rawValue),
            "serverRegion": MLFeatureValue(string: server.region.rawValue),
            "networkKind": MLFeatureValue(string: context.networkKind.rawValue),
            "latencyMilliseconds": MLFeatureValue(double: averageLatency),
            "handshakeMilliseconds": MLFeatureValue(double: averageHandshake),
            "packetLoss": MLFeatureValue(double: averagePacketLoss),
            "recentFailures": MLFeatureValue(double: recentFailures),
            "healthScore": MLFeatureValue(double: healthScore),
            "isPreviousServer": MLFeatureValue(double: server.id == context.previousServerID ? 1 : 0),
            "isQuarantined": MLFeatureValue(double: 0),
            "sampleCount": MLFeatureValue(double: Double(recentSamples.count)),
            "hourOfDay": MLFeatureValue(double: Double(context.hourOfDay))
        ]

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: features),
              let output = try? model.prediction(from: provider),
              let scoreValue = output.featureValue(for: "score")?.doubleValue else {
            return nil
        }

        return min(max(scoreValue, 0), 1)
    }
    #endif

    private func confidence(for serverID: String, historyStore: ServerQualityHistoryStore) -> Double {
        min(0.35 + Double(historyStore.samples(for: serverID).suffix(12).count) / 12 * 0.55, 0.9)
    }

    private func approximateHealthScore(
        latencyMilliseconds: Double,
        packetLoss: Double,
        recentFailures: Double
    ) -> Double {
        let latencyScore = max(0, min(1, 1 - latencyMilliseconds / 3_000))
        let lossScore = max(0, min(1, 1 - packetLoss))
        let failureScore = max(0, min(1, 1 - recentFailures / 4))
        return min(max(latencyScore * 0.35 + lossScore * 0.35 + failureScore * 0.3, 0), 1)
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
    private let reliabilityAnalyzer: ProbeReliabilityAnalyzer
    private let minimumSwitchImprovement: Double

    public init(
        selector: SmartServerSelector = SmartServerSelector(),
        reliabilityAnalyzer: ProbeReliabilityAnalyzer = ProbeReliabilityAnalyzer(),
        minimumSwitchImprovement: Double = 0.25
    ) {
        self.selector = selector
        self.reliabilityAnalyzer = reliabilityAnalyzer
        self.minimumSwitchImprovement = min(max(minimumSwitchImprovement, 0), 1)
    }

    public func assess(
        probes: [ConnectivityProbeResult],
        activeServerID: String?,
        context: ServerSelectionContext,
        servers: [SmartVPNServer],
        probeHistory: [ConnectivityProbeResult] = [],
        vpnIsConnected: Bool = false,
        directPathTrust: PathProbeTrust = .trusted,
        degradedHardDurationSeconds: TimeInterval = 0,
        quarantinedServerIDs: Set<String> = []
    ) -> PreventiveHealthAssessment {
        let directProbes = probes.filter { $0.targetKind == .directEndpoint || $0.targetKind == .dnsResolver }
        let vpnProbes = probes.filter { $0.targetKind == .vpnServer || $0.targetKind == .vpnProtectedEndpoint }
        let directReport = report(for: reliabilityAnalyzer.filteredCurrentProbes(directProbes, using: probeHistory))
        let visibleDirectReport = providerReportForDisplay(directReport, trust: directPathTrust)
        let vpnReport = report(
            for: reliabilityAnalyzer.filteredCurrentProbes(vpnProbes, using: probeHistory),
            vpnIsConnected: vpnIsConnected
        )
        let ranked = selector.rankedServers(context: context, servers: servers)
        let action = recoveryAction(
            directReport: directReport,
            vpnReport: vpnReport,
            directPathTrust: directPathTrust,
            activeServerID: activeServerID,
            rankedServers: ranked,
            degradedHardDurationSeconds: degradedHardDurationSeconds,
            quarantinedServerIDs: quarantinedServerIDs
        )
        let decisionLog = decisionLog(
            directReport: directReport,
            vpnReport: vpnReport,
            directPathTrust: directPathTrust,
            activeServerID: activeServerID,
            rankedServers: ranked,
            action: action,
            degradedHardDurationSeconds: degradedHardDurationSeconds,
            quarantinedServerIDs: quarantinedServerIDs
        )

        return PreventiveHealthAssessment(
            directPath: visibleDirectReport,
            directPathTrust: directPathTrust,
            vpnPath: vpnReport,
            recommendedAction: action,
            rankedServers: ranked,
            decisionLog: decisionLog
        )
    }

    private func recoveryAction(
        directReport: PathHealthReport,
        vpnReport: PathHealthReport,
        directPathTrust: PathProbeTrust,
        activeServerID: String?,
        rankedServers: [RankedServer],
        degradedHardDurationSeconds: TimeInterval,
        quarantinedServerIDs: Set<String>
    ) -> RecoveryAction {
        switch vpnReport.state {
        case .stalled, .down, .connectedButUnusable:
            if let action = switchOrReconnectBrokenVPN(
                directReport: directReport,
                directPathTrust: directPathTrust,
                vpnReport: vpnReport,
                activeServerID: activeServerID,
                rankedServers: rankedServers,
                quarantinedServerIDs: quarantinedServerIDs
            ) {
                return action
            }

        case .healthy:
            break
        case .degradedSoft:
            break
        case .degradedHard:
            if degradedHardDurationSeconds >= 180,
               let action = switchOrReconnectBrokenVPN(
                directReport: directReport,
                directPathTrust: directPathTrust,
                vpnReport: vpnReport,
                activeServerID: activeServerID,
                rankedServers: rankedServers,
                quarantinedServerIDs: quarantinedServerIDs,
                reasonOverride: "vpn-path-degraded-hard-persistent"
               ) {
                return action
            }
        }

        if directPathTrust.isTrusted, directReport.state == .down {
            return .askUser(reason: "provider-path-down")
        }

        if directPathTrust.isTrusted, directReport.state == .degradedSoft || directReport.state == .degradedHard {
            return .refreshDirectDNS(reason: "provider-dns-or-direct-path-degraded")
        }

        switch vpnReport.state {
        case .healthy:
            return .keepCurrent(reason: "vpn-path-healthy")
        case .degradedSoft:
            if let activeServerID {
                return .adjustParameters(
                    serverID: activeServerID,
                    adjustments: [.rehandshake, .refreshDNS],
                    reason: "vpn-path-degraded-soft"
                )
            }

            return .askUser(reason: "vpn-path-degraded-soft-without-active-server")
        case .degradedHard:
            guard degradedHardDurationSeconds >= 180 else {
                if let activeServerID {
                    return .adjustParameters(
                        serverID: activeServerID,
                        adjustments: [.rehandshake, .refreshDNS],
                        reason: "vpn-path-degraded-hard-observing"
                    )
                }

                return .askUser(reason: "vpn-path-degraded-hard-without-active-server")
            }

            if let activeServerID {
                return .reconnect(serverID: activeServerID, reason: "vpn-path-degraded-hard-no-better-candidate")
            }

            return .askUser(reason: "vpn-path-degraded-hard-no-server")
        case .stalled, .down, .connectedButUnusable:
            if let activeServerID {
                return .reconnect(serverID: activeServerID, reason: "vpn-path-\(vpnReport.state.rawValue)-no-better-candidate")
            }

            return .askUser(reason: "vpn-path-\(vpnReport.state.rawValue)-no-server")
        }
    }

    private func switchOrReconnectBrokenVPN(
        directReport: PathHealthReport,
        directPathTrust: PathProbeTrust,
        vpnReport: PathHealthReport,
        activeServerID: String?,
        rankedServers: [RankedServer],
        quarantinedServerIDs: Set<String>,
        reasonOverride: String? = nil
    ) -> RecoveryAction? {
        let requiresScoreImprovement = reasonOverride != nil
        if let replacement = replacementServer(
            rankedServers: rankedServers,
            activeServerID: activeServerID,
            quarantinedServerIDs: quarantinedServerIDs,
            requiresScoreImprovement: requiresScoreImprovement
        ) {
            return .switchServer(
                from: activeServerID,
                to: replacement.server.id,
                reason: reasonOverride ?? "vpn-path-\(vpnReport.state.rawValue)"
            )
        }

        if directPathTrust.isTrusted, directReport.state == .down {
            return .askUser(reason: "provider-path-down-no-vpn-candidate")
        }

        if let activeServerID {
            return .reconnect(
                serverID: activeServerID,
                reason: "\(reasonOverride ?? "vpn-path-\(vpnReport.state.rawValue)")-no-better-candidate"
            )
        }

        return .askUser(reason: "\(reasonOverride ?? "vpn-path-\(vpnReport.state.rawValue)")-no-server")
    }

    private func replacementServer(
        rankedServers: [RankedServer],
        activeServerID: String?,
        quarantinedServerIDs: Set<String>,
        requiresScoreImprovement: Bool
    ) -> RankedServer? {
        let currentScore = activeServerID
            .flatMap { id in rankedServers.first { $0.server.id == id }?.score }
            ?? 0

        return rankedServers.first { ranked in
            guard ranked.server.id != activeServerID,
                  !quarantinedServerIDs.contains(ranked.server.id),
                  ranked.score > 0.05
            else {
                return false
            }

            if requiresScoreImprovement {
                return ranked.score >= currentScore + minimumSwitchImprovement
            }

            return true
        }
    }

    private func decisionLog(
        directReport: PathHealthReport,
        vpnReport: PathHealthReport,
        directPathTrust: PathProbeTrust,
        activeServerID: String?,
        rankedServers: [RankedServer],
        action: RecoveryAction,
        degradedHardDurationSeconds: TimeInterval,
        quarantinedServerIDs: Set<String>
    ) -> String {
        let currentScore = activeServerID
            .flatMap { id in rankedServers.first { $0.server.id == id }?.score }
            .map { String(format: "%.2f", $0) } ?? "n/a"
        let candidate = rankedServers.first { $0.server.id != activeServerID && !quarantinedServerIDs.contains($0.server.id) }
        let candidateText = candidate.map { "\(safeLogToken($0.server.id)) score=\(String(format: "%.2f", $0.score))" } ?? "none"

        return [
            "action=\(action.logName)",
            "direct=\(directReport.state.rawValue) trust=\(directPathTrust.rawValue) score=\(String(format: "%.2f", directReport.healthScore))",
            "vpn=\(vpnReport.state.rawValue) score=\(String(format: "%.2f", vpnReport.healthScore))",
            "active=\(activeServerID.map(safeLogToken) ?? "none") score=\(currentScore)",
            "candidate=\(candidateText)",
            "hardDegradedFor=\(Int(degradedHardDurationSeconds))s",
            "quarantine=\(quarantinedServerIDs.count)"
        ].joined(separator: " · ")
    }

    private func safeLogToken(_ raw: String) -> String {
        let lowercased = raw.lowercased()
        let sensitiveMarkers = [
            "vpn://",
            "vless://",
            "ss://",
            "trojan://",
            "privatekey",
            "private_key",
            "presharedkey",
            "password=",
            "passwd="
        ]

        if sensitiveMarkers.contains(where: { lowercased.contains($0) }) || raw.contains(".") || raw.count > 80 {
            return "redacted"
        }

        return raw
    }

    private func providerReportForDisplay(_ report: PathHealthReport, trust: PathProbeTrust) -> PathHealthReport {
        guard trust == .untrustedWhileVPNActive else {
            return report
        }

        switch report.state {
        case .healthy, .degradedSoft:
            return report
        case .degradedHard, .stalled, .down, .connectedButUnusable:
            return PathHealthReport(
                state: .degradedSoft,
                healthScore: max(report.healthScore, 0.5),
                successRate: report.successRate,
                averageLatencyMilliseconds: report.averageLatencyMilliseconds,
                averagePacketLoss: report.averagePacketLoss,
                consecutiveFailures: report.consecutiveFailures,
                reason: "direct-path-not-confirmed-while-vpn-active"
            )
        }
    }

    private func report(for probes: [ConnectivityProbeResult], vpnIsConnected: Bool = false) -> PathHealthReport {
        guard !probes.isEmpty else {
            return PathHealthReport(
                state: .down,
                healthScore: 0,
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
        let endpointProbes = recent.filter { $0.targetKind == .vpnServer }
        let exitProbes = recent.filter { $0.targetKind == .vpnProtectedEndpoint }
        let endpointReachability = probeSuccessRate(for: endpointProbes)
        let exitReachability = probeSuccessRate(for: exitProbes)
        var healthScore = healthScore(
            availability: successRate,
            averageLatencyMilliseconds: averageLatency,
            averagePacketLoss: averagePacketLoss,
            endpointReachability: endpointReachability,
            exitReachability: exitReachability
        )
        let state: PathHealthState
        let reason: String

        if vpnIsConnected, !exitProbes.isEmpty, exitReachability == 0 {
            state = .connectedButUnusable
            healthScore = 0
            reason = "connected-but-no-exit"
        } else if consecutiveFailures >= 3 || successRate == 0 {
            state = .down
            reason = "consecutive-failures=\(consecutiveFailures)"
        } else if consecutiveFailures >= 2 || successRate < 0.5 {
            state = .stalled
            reason = "stalled-success-rate=\(String(format: "%.2f", successRate))"
        } else if successRate < 0.7 || averagePacketLoss > 0.2 || (averageLatency ?? 0) > 2_500 || healthScore < 0.45 {
            state = .degradedHard
            reason = "degraded-hard-score=\(String(format: "%.2f", healthScore))"
        } else if successRate < 0.85 || averagePacketLoss > 0.08 || (averageLatency ?? 0) > 1_200 || healthScore < 0.7 {
            state = .degradedSoft
            reason = "degraded-soft-score=\(String(format: "%.2f", healthScore))"
        } else {
            state = .healthy
            reason = "healthy"
        }

        return PathHealthReport(
            state: state,
            healthScore: healthScore,
            successRate: successRate,
            averageLatencyMilliseconds: averageLatency,
            averagePacketLoss: averagePacketLoss,
            consecutiveFailures: consecutiveFailures,
            reason: reason
        )
    }

    private func probeSuccessRate(for probes: [ConnectivityProbeResult]) -> Double {
        guard !probes.isEmpty else {
            return 1
        }

        return Double(probes.filter(\.succeeded).count) / Double(probes.count)
    }

    private func healthScore(
        availability: Double,
        averageLatencyMilliseconds: Double?,
        averagePacketLoss: Double,
        endpointReachability: Double,
        exitReachability: Double
    ) -> Double {
        let latencyScore: Double
        if let averageLatencyMilliseconds {
            latencyScore = max(0, min(1, 1 - averageLatencyMilliseconds / 3_000))
        } else {
            latencyScore = availability > 0 ? 0.5 : 0
        }

        let packetLossScore = max(0, min(1, 1 - averagePacketLoss))
        return min(max(
            availability * 0.4
                + latencyScore * 0.2
                + packetLossScore * 0.2
                + endpointReachability * 0.1
                + exitReachability * 0.1,
            0
        ), 1)
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
