import XCTest

@testable import SmartServerSelection

final class SmartServerSelectionTests: XCTestCase {
    func testCurrentRegionUsesDirectProviderDNSAndBypassesScorer() {
        let selector = SmartServerSelector()
        let decision = selector.decideRoute(
            destinationRegion: .current,
            context: .ruInRussia,
            servers: [.israelFast, .germanySlow]
        )

        XCTAssertEqual(decision.action, .directProviderDNS)
        XCTAssertEqual(decision.source, "current-region-direct-provider-dns")
        XCTAssertTrue(decision.rankedServers.isEmpty)
    }

    func testHomeRegionUsesHomeVPNServer() {
        let selector = SmartServerSelector()
        let decision = selector.decideRoute(
            destinationRegion: .home,
            context: .ruInRussia,
            servers: [.israelFast, .germanySlow]
        )

        XCTAssertEqual(decision.action, .vpn(serverID: "il-1", region: "IL"))
        XCTAssertEqual(decision.source, "home-region-vpn")
    }

    func testForeignTrafficUsesFastestHealthyVPN() {
        let selector = SmartServerSelector()

        selector.record(.sample(serverID: "il-1", region: "IL", latency: 180, handshake: 300, loss: 0.01))
        selector.record(.sample(serverID: "de-1", region: "DE", latency: 55, handshake: 120, loss: 0))

        let decision = selector.decideRoute(
            destinationRegion: .foreign,
            context: .ruInRussia,
            servers: [.israelFast, .germanySlow]
        )

        XCTAssertEqual(decision.action, .vpn(serverID: "de-1", region: "DE"))
        XCTAssertEqual(decision.source, "fastest-vpn-heuristic")
    }

    func testUnhealthyServerIsIgnored() {
        let selector = SmartServerSelector()
        var unhealthyGermany = SmartVPNServer.germanySlow
        unhealthyGermany.healthState = .unhealthy

        selector.record(.sample(serverID: "de-1", region: "DE", latency: 20, handshake: 50, loss: 0))
        selector.record(.sample(serverID: "il-1", region: "IL", latency: 200, handshake: 400, loss: 0.02))

        let decision = selector.decideRoute(
            destinationRegion: .foreign,
            context: .ruInRussia,
            servers: [.israelFast, unhealthyGermany]
        )

        XCTAssertEqual(decision.action, .vpn(serverID: "il-1", region: "IL"))
    }

    func testNoHealthyServerFallsBackToAsk() {
        let selector = SmartServerSelector()
        var unhealthyIsrael = SmartVPNServer.israelFast
        unhealthyIsrael.healthState = .unhealthy

        let decision = selector.decideRoute(
            destinationRegion: .home,
            context: .ruInRussia,
            servers: [unhealthyIsrael]
        )

        XCTAssertEqual(decision.action, .ask(reason: "no-healthy-server-for-IL"))
    }

    func testHistorySampleDoesNotContainRawDomainOrVpnConfigFields() {
        let sample = ServerQualitySample.sample(
            serverID: "il-1",
            region: "IL",
            latency: 100,
            handshake: 200,
            loss: 0.01
        )
        let encoded = try! JSONEncoder().encode(sample)
        let json = String(data: encoded, encoding: .utf8)!

        XCTAssertFalse(json.contains("vpn://"))
        XCTAssertFalse(json.contains("privateKey"))
        XCTAssertFalse(json.contains("example.com"))
    }

    func testDecisionLogRedactsRawKeysAndDomains() {
        let monitor = PreventiveVPNHealthMonitor()
        let assessment = monitor.assess(
            probes: .healthyDirect + .downVPN(serverID: "vpn://secret.example.com/privateKey=abc"),
            activeServerID: "vpn://secret.example.com/privateKey=abc",
            context: .ruInRussia,
            servers: [
                SmartVPNServer(
                    id: "vless://secret.example.com?password=abc",
                    region: "DE",
                    displayName: "Sensitive Candidate",
                    protocolKind: .singBox,
                    lastLatencyMilliseconds: 20
                )
            ]
        )

        XCTAssertFalse(assessment.decisionLog.contains("vpn://"))
        XCTAssertFalse(assessment.decisionLog.contains("vless://"))
        XCTAssertFalse(assessment.decisionLog.contains("secret.example.com"))
        XCTAssertFalse(assessment.decisionLog.contains("privateKey"))
        XCTAssertFalse(assessment.decisionLog.contains("password"))
    }

    func testPreviousServerWinsTieForStability() {
        let selector = SmartServerSelector()
        selector.record(.sample(serverID: "il-1", region: "IL", latency: 100, handshake: 200, loss: 0))
        selector.record(.sample(serverID: "de-1", region: "DE", latency: 100, handshake: 200, loss: 0))

        let ranked = selector.rankedServers(
            context: ServerSelectionContext(
                currentRegion: "RU",
                homeRegion: "IL",
                networkKind: .wifi,
                hourOfDay: 12,
                previousServerID: "de-1"
            ),
            servers: [.israelFast, .germanySlow]
        )

        XCTAssertEqual(ranked.first?.server.id, "de-1")
    }

    func testCoreMLScorerFallsBackToHeuristicWhenModelIsMissing() {
        let selector = SmartServerSelector(scorer: CoreMLServerScorer(modelURL: nil))
        selector.record(.sample(serverID: "il-1", region: "IL", latency: 250, handshake: 500, loss: 0.05))
        selector.record(.sample(serverID: "de-1", region: "DE", latency: 40, handshake: 100, loss: 0))

        let ranked = selector.rankedServers(
            context: .ruInRussia,
            servers: [.israelFast, .germanySlow]
        )

        XCTAssertEqual(ranked.first?.server.id, "de-1")
        XCTAssertTrue(ranked.first?.reason.contains("latency=") ?? false)
    }

    func testPreventiveMonitorKeepsHealthyVPN() {
        let monitor = PreventiveVPNHealthMonitor()
        let assessment = monitor.assess(
            probes: .healthyDirect + .healthyVPN(serverID: "il-1"),
            activeServerID: "il-1",
            context: .ruInRussia,
            servers: [.israelFast, .germanySlow]
        )

        XCTAssertEqual(assessment.directPath.state, .healthy)
        XCTAssertEqual(assessment.vpnPath.state, .healthy)
        XCTAssertEqual(assessment.recommendedAction, .keepCurrent(reason: "vpn-path-healthy"))
    }

    func testPreventiveMonitorAdjustsParametersForDegradedVPN() {
        let monitor = PreventiveVPNHealthMonitor()
        let assessment = monitor.assess(
            probes: .healthyDirect + .degradedVPN(serverID: "il-1"),
            activeServerID: "il-1",
            context: .ruInRussia,
            servers: [.israelFast, .germanySlow]
        )

        XCTAssertEqual(assessment.vpnPath.state, .degradedSoft)
        XCTAssertEqual(
            assessment.recommendedAction,
            .adjustParameters(serverID: "il-1", adjustments: [.rehandshake, .refreshDNS], reason: "vpn-path-degraded-soft")
        )
    }

    func testPreventiveMonitorSwitchesAfterPersistentHardDegradedVPN() {
        let selector = SmartServerSelector()
        selector.record(.sample(serverID: "il-1", region: "IL", latency: 2_800, handshake: 2_800, loss: 0.25))
        selector.record(.sample(serverID: "de-1", region: "DE", latency: 40, handshake: 100, loss: 0))
        let monitor = PreventiveVPNHealthMonitor(selector: selector)

        let assessment = monitor.assess(
            probes: .healthyDirect + .hardDegradedVPN(serverID: "il-1"),
            activeServerID: "il-1",
            context: .ruInRussia,
            servers: [.israelFast, .germanySlow],
            degradedHardDurationSeconds: 181
        )

        XCTAssertEqual(assessment.vpnPath.state, .degradedHard)
        XCTAssertEqual(
            assessment.recommendedAction,
            .switchServer(from: "il-1", to: "de-1", reason: "vpn-path-degraded-hard-persistent")
        )
    }

    func testPreventiveMonitorDetectsConnectedButUnusableVPN() {
        let selector = SmartServerSelector()
        selector.record(.sample(serverID: "il-1", region: "IL", latency: 250, handshake: 500, loss: 0.05))
        selector.record(.sample(serverID: "de-1", region: "DE", latency: 40, handshake: 100, loss: 0))
        let monitor = PreventiveVPNHealthMonitor(selector: selector)

        let assessment = monitor.assess(
            probes: .healthyDirect + .connectedButNoExitVPN(serverID: "il-1"),
            activeServerID: "il-1",
            context: .ruInRussia,
            servers: [.israelFast, .germanySlow],
            vpnIsConnected: true
        )

        XCTAssertEqual(assessment.vpnPath.state, .connectedButUnusable)
        XCTAssertEqual(
            assessment.recommendedAction,
            .switchServer(from: "il-1", to: "de-1", reason: "vpn-path-connectedButUnusable")
        )
    }

    func testConnectedButUnusableIgnoresStaleActiveHistoryWhenSelectingReplacement() {
        let selector = SmartServerSelector()
        for _ in 0..<12 {
            selector.record(.sample(serverID: "il-1", region: "IL", latency: 20, handshake: 60, loss: 0))
        }
        let monitor = PreventiveVPNHealthMonitor(selector: selector)

        let assessment = monitor.assess(
            probes: .healthyDirect + .connectedButNoExitVPN(serverID: "il-1"),
            activeServerID: "il-1",
            context: .ruInRussia,
            servers: [.israelFast, .germanySlow],
            vpnIsConnected: true
        )

        XCTAssertEqual(assessment.rankedServers.first?.server.id, "il-1")
        XCTAssertEqual(assessment.vpnPath.healthScore, 0)
        XCTAssertEqual(
            assessment.recommendedAction,
            .switchServer(from: "il-1", to: "de-1", reason: "vpn-path-connectedButUnusable")
        )
    }

    func testPersistentHardDegradedStillRequiresMeaningfullyBetterCandidate() {
        let selector = SmartServerSelector()
        for _ in 0..<12 {
            selector.record(.sample(serverID: "il-1", region: "IL", latency: 20, handshake: 60, loss: 0))
        }
        let monitor = PreventiveVPNHealthMonitor(selector: selector)

        let assessment = monitor.assess(
            probes: .healthyDirect + .hardDegradedVPN(serverID: "il-1"),
            activeServerID: "il-1",
            context: .ruInRussia,
            servers: [.israelFast, .germanySlow],
            degradedHardDurationSeconds: 181
        )

        XCTAssertEqual(assessment.vpnPath.state, .degradedHard)
        XCTAssertEqual(
            assessment.recommendedAction,
            .reconnect(serverID: "il-1", reason: "vpn-path-degraded-hard-persistent-no-better-candidate")
        )
    }

    func testUntrustedProviderFailureDoesNotBlockUnusableVPNSwitch() {
        let selector = SmartServerSelector()
        selector.record(.sample(serverID: "il-1", region: "IL", latency: 2_500, handshake: 2_500, loss: 0.3))
        selector.record(.sample(serverID: "de-1", region: "DE", latency: 40, handshake: 100, loss: 0))
        let monitor = PreventiveVPNHealthMonitor(selector: selector)

        let assessment = monitor.assess(
            probes: .downDirect + .connectedButNoExitVPN(serverID: "il-1"),
            activeServerID: "il-1",
            context: .ruInRussia,
            servers: [.israelFast, .germanySlow],
            vpnIsConnected: true,
            directPathTrust: .untrustedWhileVPNActive
        )

        XCTAssertEqual(assessment.directPath.state, .degradedSoft)
        XCTAssertEqual(assessment.directPath.reason, "direct-path-not-confirmed-while-vpn-active")
        XCTAssertEqual(assessment.vpnPath.state, .connectedButUnusable)
        XCTAssertEqual(
            assessment.recommendedAction,
            .switchServer(from: "il-1", to: "de-1", reason: "vpn-path-connectedButUnusable")
        )
        XCTAssertTrue(assessment.decisionLog.contains("trust=untrustedWhileVPNActive"))
    }

    func testTrustedProviderDownBlocksWhenNoVPNCandidateExists() {
        let monitor = PreventiveVPNHealthMonitor()

        let assessment = monitor.assess(
            probes: .downDirect + .downVPN(serverID: "il-1"),
            activeServerID: "il-1",
            context: .ruInRussia,
            servers: [.israelFast],
            vpnIsConnected: true,
            directPathTrust: .trusted
        )

        XCTAssertEqual(assessment.directPath.state, .down)
        XCTAssertEqual(assessment.vpnPath.state, .connectedButUnusable)
        XCTAssertEqual(assessment.recommendedAction, .askUser(reason: "provider-path-down-no-vpn-candidate"))
    }

    func testPreventiveMonitorSkipsQuarantinedCandidate() {
        let selector = SmartServerSelector()
        selector.record(.sample(serverID: "il-1", region: "IL", latency: 2_800, handshake: 2_800, loss: 0.25))
        selector.record(.sample(serverID: "de-1", region: "DE", latency: 40, handshake: 100, loss: 0))
        let monitor = PreventiveVPNHealthMonitor(selector: selector)

        let assessment = monitor.assess(
            probes: .healthyDirect + .downVPN(serverID: "il-1"),
            activeServerID: "il-1",
            context: .ruInRussia,
            servers: [.israelFast, .germanySlow],
            quarantinedServerIDs: ["de-1"]
        )

        XCTAssertEqual(assessment.vpnPath.state, .down)
        XCTAssertEqual(
            assessment.recommendedAction,
            .reconnect(serverID: "il-1", reason: "vpn-path-down-no-better-candidate")
        )
    }

    func testPreventiveMonitorSwitchesServerWhenVPNStalls() {
        let selector = SmartServerSelector()
        selector.record(.sample(serverID: "il-1", region: "IL", latency: 250, handshake: 500, loss: 0.05))
        selector.record(.sample(serverID: "de-1", region: "DE", latency: 40, handshake: 100, loss: 0))
        let monitor = PreventiveVPNHealthMonitor(selector: selector)

        let assessment = monitor.assess(
            probes: .healthyDirect + .downVPN(serverID: "il-1"),
            activeServerID: "il-1",
            context: .ruInRussia,
            servers: [.israelFast, .germanySlow]
        )

        XCTAssertEqual(assessment.vpnPath.state, .down)
        XCTAssertEqual(
            assessment.recommendedAction,
            .switchServer(from: "il-1", to: "de-1", reason: "vpn-path-down")
        )
    }

    func testPreventiveMonitorDoesNotHideProviderPathFailure() {
        let monitor = PreventiveVPNHealthMonitor()
        let assessment = monitor.assess(
            probes: .downDirect + .healthyVPN(serverID: "il-1"),
            activeServerID: "il-1",
            context: .ruInRussia,
            servers: [.israelFast, .germanySlow]
        )

        XCTAssertEqual(assessment.directPath.state, .down)
        XCTAssertEqual(assessment.recommendedAction, .askUser(reason: "provider-path-down"))
    }

    func testProbeReliabilityRanksStableTargetsFirst() {
        let analyzer = ProbeReliabilityAnalyzer(minimumSamplesForFiltering: 4)
        let stable = (0..<6).map {
            ConnectivityProbeResult.probe(
                targetID: "foreign-cloudflare-204",
                targetKind: .vpnProtectedEndpoint,
                serverID: "ee-1",
                method: .httpHead,
                succeeded: true,
                latency: 90 + Double($0)
            )
        }
        let noisy = (0..<6).map {
            ConnectivityProbeResult.probe(
                targetID: "foreign-gstatic-204",
                targetKind: .vpnProtectedEndpoint,
                serverID: "ee-1",
                method: .httpHead,
                succeeded: $0 == 0,
                latency: 500
            )
        }

        let summaries = analyzer.summaries(from: stable + noisy, serverID: "ee-1", targetKind: .vpnProtectedEndpoint)

        XCTAssertEqual(summaries.first?.targetID, "foreign-cloudflare-204")
        XCTAssertGreaterThan(summaries.first?.reliabilityScore ?? 0, summaries.last?.reliabilityScore ?? 0)
    }

    func testMonitorIgnoresHistoricallyUnreliableFailedProbe() {
        let monitor = PreventiveVPNHealthMonitor(
            reliabilityAnalyzer: ProbeReliabilityAnalyzer(minimumSamplesForFiltering: 4, minimumReliabilityScore: 0.45)
        )
        let unreliableHistory = (0..<6).map { _ in
            ConnectivityProbeResult.probe(
                targetID: "foreign-gstatic-204",
                targetKind: .vpnProtectedEndpoint,
                serverID: "ee-1",
                method: .httpHead,
                succeeded: false
            )
        }
        let current = ConnectivityProbeResult.probe(
            targetID: "foreign-gstatic-204",
            targetKind: .vpnProtectedEndpoint,
            serverID: "ee-1",
            method: .httpHead,
            succeeded: false
        )

        let assessment = monitor.assess(
            probes: .healthyDirect + .healthyVPN(serverID: "ee-1") + [current],
            activeServerID: "ee-1",
            context: .ruInRussia,
            servers: [.israelFast, .germanySlow],
            probeHistory: unreliableHistory
        )

        XCTAssertEqual(assessment.vpnPath.state, .healthy)
    }
}

private extension ServerSelectionContext {
    static let ruInRussia = ServerSelectionContext(
        currentRegion: "RU",
        homeRegion: "IL",
        networkKind: .wifi,
        providerASN: "AS12389",
        hourOfDay: 12
    )
}

private extension SmartVPNServer {
    static let israelFast = SmartVPNServer(
        id: "il-1",
        region: "IL",
        displayName: "Israel 1",
        protocolKind: .amneziaWG,
        lastLatencyMilliseconds: 160
    )

    static let germanySlow = SmartVPNServer(
        id: "de-1",
        region: "DE",
        displayName: "Germany 1",
        protocolKind: .amneziaWG,
        lastLatencyMilliseconds: 220
    )
}

private extension ServerQualitySample {
    static func sample(
        serverID: String,
        region: RegionCode,
        latency: Double,
        handshake: Double,
        loss: Double,
        failures: Int = 0
    ) -> ServerQualitySample {
        ServerQualitySample(
            serverID: serverID,
            region: region,
            networkKind: .wifi,
            providerASNHash: "hashed-asn",
            latencyMilliseconds: latency,
            packetLoss: loss,
            handshakeMilliseconds: handshake,
            recentFailureCount: failures,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}

private extension Array where Element == ConnectivityProbeResult {
    static let healthyDirect: [ConnectivityProbeResult] = [
        .probe(targetID: "provider-dns", targetKind: .dnsResolver, method: .dnsQuery, succeeded: true, latency: 24),
        .probe(targetID: "local-site", targetKind: .directEndpoint, method: .httpHead, succeeded: true, latency: 42),
        .probe(targetID: "provider-dns", targetKind: .dnsResolver, method: .dnsQuery, succeeded: true, latency: 25)
    ]

    static let downDirect: [ConnectivityProbeResult] = [
        .probe(targetID: "provider-dns", targetKind: .dnsResolver, method: .dnsQuery, succeeded: false),
        .probe(targetID: "local-site", targetKind: .directEndpoint, method: .httpHead, succeeded: false),
        .probe(targetID: "provider-dns", targetKind: .dnsResolver, method: .dnsQuery, succeeded: false)
    ]

    static func healthyVPN(serverID: String) -> [ConnectivityProbeResult] {
        [
            .probe(targetID: "vpn-handshake", targetKind: .vpnServer, serverID: serverID, method: .tunnelHandshake, succeeded: true, latency: 120),
            .probe(targetID: "foreign-site", targetKind: .vpnProtectedEndpoint, serverID: serverID, method: .httpHead, succeeded: true, latency: 160),
            .probe(targetID: "vpn-dns", targetKind: .vpnProtectedEndpoint, serverID: serverID, method: .dnsQuery, succeeded: true, latency: 140)
        ]
    }

    static func degradedVPN(serverID: String) -> [ConnectivityProbeResult] {
        [
            .probe(targetID: "vpn-handshake", targetKind: .vpnServer, serverID: serverID, method: .tunnelHandshake, succeeded: true, latency: 1_350, loss: 0.1),
            .probe(targetID: "foreign-site", targetKind: .vpnProtectedEndpoint, serverID: serverID, method: .httpHead, succeeded: true, latency: 1_420, loss: 0.12),
            .probe(targetID: "vpn-dns", targetKind: .vpnProtectedEndpoint, serverID: serverID, method: .dnsQuery, succeeded: true, latency: 1_250, loss: 0.09)
        ]
    }

    static func hardDegradedVPN(serverID: String) -> [ConnectivityProbeResult] {
        [
            .probe(targetID: "vpn-handshake", targetKind: .vpnServer, serverID: serverID, method: .tunnelHandshake, succeeded: true, latency: 2_800, loss: 0.25),
            .probe(targetID: "foreign-site", targetKind: .vpnProtectedEndpoint, serverID: serverID, method: .httpHead, succeeded: true, latency: 2_900, loss: 0.25),
            .probe(targetID: "vpn-dns", targetKind: .vpnProtectedEndpoint, serverID: serverID, method: .dnsQuery, succeeded: true, latency: 2_700, loss: 0.25)
        ]
    }

    static func connectedButNoExitVPN(serverID: String) -> [ConnectivityProbeResult] {
        [
            .probe(targetID: "vpn-handshake", targetKind: .vpnServer, serverID: serverID, method: .tunnelHandshake, succeeded: true, latency: 120),
            .probe(targetID: "foreign-site", targetKind: .vpnProtectedEndpoint, serverID: serverID, method: .httpHead, succeeded: false),
            .probe(targetID: "exit-ip", targetKind: .vpnProtectedEndpoint, serverID: serverID, method: .httpHead, succeeded: false)
        ]
    }

    static func downVPN(serverID: String) -> [ConnectivityProbeResult] {
        [
            .probe(targetID: "vpn-handshake", targetKind: .vpnServer, serverID: serverID, method: .tunnelHandshake, succeeded: false),
            .probe(targetID: "foreign-site", targetKind: .vpnProtectedEndpoint, serverID: serverID, method: .httpHead, succeeded: false),
            .probe(targetID: "vpn-dns", targetKind: .vpnProtectedEndpoint, serverID: serverID, method: .dnsQuery, succeeded: false)
        ]
    }
}

private extension ConnectivityProbeResult {
    static func probe(
        targetID: String,
        targetKind: ProbeTargetKind,
        serverID: String? = nil,
        method: ProbeMethod,
        succeeded: Bool,
        latency: Double? = nil,
        loss: Double = 0
    ) -> ConnectivityProbeResult {
        ConnectivityProbeResult(
            targetID: targetID,
            targetKind: targetKind,
            serverID: serverID,
            method: method,
            succeeded: succeeded,
            latencyMilliseconds: latency,
            packetLoss: loss,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}
