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

        XCTAssertEqual(assessment.vpnPath.state, .degraded)
        XCTAssertEqual(
            assessment.recommendedAction,
            .adjustParameters(serverID: "il-1", adjustments: [.rehandshake, .refreshDNS], reason: "vpn-path-degraded")
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
