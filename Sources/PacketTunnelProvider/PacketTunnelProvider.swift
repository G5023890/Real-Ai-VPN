import AmneziaConfig
import Foundation
import Network
import NetworkExtension
import os
import RealVPNCore
import UserNotifications
#if !SINGBOX_TUNNEL
import WireGuardKit
#endif

private let packetTunnelLogger = Logger(
    subsystem: "com.codex.RealAiVPN.PacketTunnel",
    category: "PacketTunnelProvider"
)

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let decoder = AmneziaConfigDecoder()
    private let shadowrocketParser = ShadowrocketVLESSConfigParser()
    private let diagnosticsStore = TunnelDiagnosticsStore()
    private let profileStore = AmneziaConfigProfileStore(
        accessGroup: AmneziaPremiumKeyStore.sharedAccessGroup,
        allowsAuthenticationUI: false
    )
    private let premiumKeyStore = AmneziaPremiumKeyStore(
        accessGroup: AmneziaPremiumKeyStore.sharedAccessGroup,
        allowsAuthenticationUI: false
    )
    private lazy var singBoxRuntime = SingBoxTunnelRuntime(provider: self)
#if !SINGBOX_TUNNEL
    private lazy var adapter = WireGuardAdapter(with: self) { logLevel, message in
        switch logLevel {
        case .verbose:
            packetTunnelLogger.debug("\(message, privacy: .public)")
        case .error:
            packetTunnelLogger.error("\(message, privacy: .public)")
        }
    }
#endif

    override func startTunnel(options: [String: NSObject]?) async throws {
        packetTunnelLogger.info("Starting Real Ai Router packet tunnel")
        saveDiagnostic(stage: "startTunnel", message: "PacketTunnelProvider entered startTunnel.")
        NSLog("RealAiVPN PacketTunnel startTunnel optionsHasConfig=%@",
              (((options?["amneziaVPNURL"] as? String) ?? (options?["amneziaVPNURL"] as? NSString).map(String.init))?.isEmpty == false) ? "true" : "false")

        let importedConfig = ((options?["amneziaVPNURL"] as? String) ?? (options?["amneziaVPNURL"] as? NSString).map(String.init))
            ?? storedAmneziaConfig()
        let routingExceptions = RoutingExceptionCodec.decode(
            (options?["routingExceptions"] as? String) ?? (options?["routingExceptions"] as? NSString).map(String.init)
        )
        let killSwitchEnabled = (options?["killSwitchEnabled"] as? NSNumber)?.boolValue ?? false
        let dnsProtectionEnabled = (options?["dnsProtectionEnabled"] as? NSNumber)?.boolValue ?? true
        let localNetworkAccessEnabled = (options?["localNetworkAccessEnabled"] as? NSNumber)?.boolValue ?? true
        let ipv6LeakProtectionEnabled = (options?["ipv6LeakProtectionEnabled"] as? NSNumber)?.boolValue ?? true

        guard let importedConfig, !importedConfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            packetTunnelLogger.error("Missing transient Amnezia config")
            saveDiagnostic(stage: "missing-config", message: "No transient or stored config was available.")
            NSLog("RealAiVPN PacketTunnel missing transient config")
            throw PacketTunnelProviderError.missingAmneziaKey
        }

        if let shadowrocketConfig = try? shadowrocketParser.parse(importedConfig) {
            packetTunnelLogger.info("Decoded Shadowrocket VLESS profile: \(shadowrocketConfig.redactedSummary, privacy: .public)")
            saveDiagnostic(stage: "decoded-vless", message: shadowrocketConfig.redactedSummary)
            NSLog("RealAiVPN PacketTunnel decoded Shadowrocket profile=%@", shadowrocketConfig.redactedSummary)
            do {
                try await startSingBoxTunnel(
                    with: shadowrocketConfig,
                    routingExceptions: routingExceptions,
                    killSwitchEnabled: killSwitchEnabled,
                    dnsProtectionEnabled: dnsProtectionEnabled,
                    localNetworkAccessEnabled: localNetworkAccessEnabled,
                    ipv6LeakProtectionEnabled: ipv6LeakProtectionEnabled
                )
                saveDiagnostic(stage: "started-vless", message: "sing-box tunnel start returned successfully.")
            } catch {
                saveDiagnostic(stage: "vless-failed", message: error.localizedDescription)
                throw error
            }
            return
        }

#if SINGBOX_TUNNEL
        saveDiagnostic(stage: "invalid-singbox-config", message: "SingBox provider received a non-VLESS config.")
        throw PacketTunnelProviderError.invalidAmneziaConfig
#else
        let config: AmneziaWireGuardConfig
        do {
            config = try decoder.decodeImportedWireGuardConfig(from: importedConfig)
            packetTunnelLogger.info("Decoded Amnezia config: \(config.redactedSummary, privacy: .public)")
            saveDiagnostic(stage: "decoded-awg", message: config.redactedSummary)
            NSLog("RealAiVPN PacketTunnel decoded Amnezia config=%@", config.redactedSummary)
        } catch {
            packetTunnelLogger.error("Failed to decode Amnezia config: \(error.localizedDescription, privacy: .public)")
            saveDiagnostic(stage: "decode-failed", message: error.localizedDescription)
            NSLog("RealAiVPN PacketTunnel failed to decode config: %@", error.localizedDescription)
            throw PacketTunnelProviderError.invalidAmneziaConfig
        }

        do {
            if dnsProtectionEnabled {
                saveDiagnostic(
                    stage: "split-dns-provider-lane-unavailable",
                    message: "split-dns-provider-lane unavailable for AWG; using profile DNS only."
                )
            }
            try await startAmneziaWireGuardTunnel(
                with: config,
                routingExceptions: routingExceptions,
                killSwitchEnabled: killSwitchEnabled,
                localNetworkAccessEnabled: localNetworkAccessEnabled,
                ipv6LeakProtectionEnabled: ipv6LeakProtectionEnabled
            )
            saveDiagnostic(stage: "started-awg", message: "AmneziaWG tunnel start returned successfully.")
        } catch {
            saveDiagnostic(stage: "awg-failed", message: error.localizedDescription)
            throw error
        }
#endif
    }

    private func saveDiagnostic(stage: String, message: String) {
        diagnosticsStore.save(TunnelDiagnosticSnapshot(
            providerBundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            stage: stage,
            message: message
        ))
    }

    private func storedAmneziaConfig() -> String? {
        if let profile = try? profileStore.load().activeProfile {
            return profile.config
        }

        return try? premiumKeyStore.read()
    }

    private func startAmneziaWireGuardTunnel(
        with config: AmneziaWireGuardConfig,
        routingExceptions: RoutingExceptionCollection,
        killSwitchEnabled: Bool,
        localNetworkAccessEnabled: Bool,
        ipv6LeakProtectionEnabled: Bool
    ) async throws {
#if SINGBOX_TUNNEL
        throw PacketTunnelProviderError.invalidAmneziaConfig
#else
        let tunnelConfiguration = try config.makeTunnelConfiguration(
            named: "Real Ai Router",
            routingExceptions: routingExceptions,
            killSwitchEnabled: killSwitchEnabled,
            localNetworkAccessEnabled: localNetworkAccessEnabled,
            ipv6LeakProtectionEnabled: ipv6LeakProtectionEnabled
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            adapter.start(tunnelConfiguration: tunnelConfiguration) { error in
                if let error {
                    continuation.resume(throwing: PacketTunnelProviderError.adapterStartFailed(String(describing: error)))
                } else {
                    packetTunnelLogger.info("AmneziaWG tunnel started")
                    continuation.resume()
                }
            }
        }
#endif
    }

    private func startSingBoxTunnel(
        with config: ShadowrocketVLESSConfig,
        routingExceptions: RoutingExceptionCollection,
        killSwitchEnabled: Bool,
        dnsProtectionEnabled: Bool,
        localNetworkAccessEnabled: Bool,
        ipv6LeakProtectionEnabled: Bool
    ) async throws {
        let singBoxConfig = try SingBoxConfigBuilder().build(
            from: config,
            routeOverrides: singBoxRouteOverrides(
                from: routingExceptions,
                localNetworkAccessEnabled: localNetworkAccessEnabled,
                ipv6LeakProtectionEnabled: ipv6LeakProtectionEnabled
            ),
            dnsProtectionEnabled: dnsProtectionEnabled
        )
        packetTunnelLogger.info("Prepared sing-box config for \(config.endpoint, privacy: .public), bytes=\(singBoxConfig.jsonString.utf8.count, privacy: .public)")
        saveDiagnostic(
            stage: "singbox-config-built",
            message: dnsProtectionEnabled
                ? "Config bytes: \(singBoxConfig.jsonString.utf8.count). Provider DNS lane: Yandex DNS."
                : "Config bytes: \(singBoxConfig.jsonString.utf8.count). Profile DNS only."
        )
        try await singBoxRuntime.start(configJSON: singBoxConfig.jsonString, killSwitchEnabled: killSwitchEnabled)
    }

    private func singBoxRouteOverrides(
        from routingExceptions: RoutingExceptionCollection,
        localNetworkAccessEnabled: Bool,
        ipv6LeakProtectionEnabled: Bool
    ) -> SingBoxRouteOverrides {
        var overrides = SingBoxRouteOverrides()
        var forceHostRoutes: [String] = []
        for rule in routingExceptions.enabledRules {
            let normalized = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                continue
            }

            if isCIDRLikeRoute(normalized) {
                switch rule.mode {
                case .forceVPN:
                    overrides.forceVPNIPCIDRs.append(normalized)
                    forceHostRoutes.append(normalized)
                case .bypassVPN:
                    overrides.bypassVPNIPCIDRs.append(normalized)
                }
            } else {
                switch rule.mode {
                case .forceVPN:
                    overrides.forceVPNDomainSuffixes.append(normalized)
                case .bypassVPN:
                    overrides.bypassVPNDomainSuffixes.append(normalized)
                }
            }
        }

        let localProviderRanges = localRouteExcludes(
            localNetworkAccessEnabled: localNetworkAccessEnabled,
            ipv6LeakProtectionEnabled: ipv6LeakProtectionEnabled
        )
        let ruRanges = subtract(forceHostRoutes: forceHostRoutes, from: loadBundledCIDRs(resource: "ru-aggregated", extension: "zone"))
        overrides.systemRouteExcludeIPCIDRs = localProviderRanges + ruRanges + overrides.bypassVPNIPCIDRs
        packetTunnelLogger.info("Applying sing-box system route excludes: local=\(localProviderRanges.count, privacy: .public) ru=\(ruRanges.count, privacy: .public)")

        return overrides
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        packetTunnelLogger.info("Stopping packet tunnel, reason: \(reason.rawValue)")
        saveDiagnostic(
            stage: "stopTunnel",
            message: "reason=\(reason.diagnosticName) raw=\(reason.rawValue)"
        )
        await singBoxRuntime.stop()
#if !SINGBOX_TUNNEL
        await withCheckedContinuation { continuation in
            adapter.stop { error in
                if let error {
                    if case .invalidState = error {
                        packetTunnelLogger.debug("AmneziaWG adapter was already stopped")
                    } else {
                        packetTunnelLogger.error("Failed to stop AmneziaWG adapter: \(String(describing: error), privacy: .public)")
                    }
                }
                continuation.resume()
            }
        }
#endif

        notifyUnexpectedTunnelStopIfNeeded(reason: reason)
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        "ok".data(using: .utf8)
    }

    private func notifyUnexpectedTunnelStopIfNeeded(reason: NEProviderStopReason) {
        guard shouldNotifyUnexpectedStop(reason: reason) else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Real Ai Router disconnected"
        content.body = "Tunnel dropped or reset for \(activeProfileName())."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "real-ai-vpn-packet-tunnel-stop-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                packetTunnelLogger.error("Could not schedule tunnel stop notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func shouldNotifyUnexpectedStop(reason: NEProviderStopReason) -> Bool {
        switch reason {
        case .userInitiated, .providerDisabled, .configurationDisabled, .configurationRemoved:
            return false
        default:
            return true
        }
    }

    private func activeProfileName() -> String {
        if let profile = try? profileStore.load().activeProfile {
            return profile.displayName
        }

        if let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol,
           let providerConfiguration = tunnelProtocol.providerConfiguration,
           let serverID = providerConfiguration["serverID"] as? String {
            return serverID
        }

        return "active profile"
    }
}

private extension NEProviderStopReason {
    var diagnosticName: String {
        switch self {
        case .none:
            return "none"
        case .userInitiated:
            return "userInitiated"
        case .providerFailed:
            return "providerFailed"
        case .noNetworkAvailable:
            return "noNetworkAvailable"
        case .unrecoverableNetworkChange:
            return "unrecoverableNetworkChange"
        case .providerDisabled:
            return "providerDisabled"
        case .authenticationCanceled:
            return "authenticationCanceled"
        case .configurationFailed:
            return "configurationFailed"
        case .idleTimeout:
            return "idleTimeout"
        case .configurationDisabled:
            return "configurationDisabled"
        case .configurationRemoved:
            return "configurationRemoved"
        case .superceded:
            return "superceded"
        case .userLogout:
            return "userLogout"
        case .userSwitch:
            return "userSwitch"
        case .connectionFailed:
            return "connectionFailed"
        case .sleep:
            return "sleep"
        case .appUpdate:
            return "appUpdate"
        case .internalError:
            return "internalError"
        @unknown default:
            return "unknown"
        }
    }
}

enum PacketTunnelProviderError: LocalizedError {
    case missingAmneziaKey
    case invalidAmneziaConfig
    case invalidWireGuardConfig(String)
    case adapterStartFailed(String)
    case singBoxRuntimeMissing

    var errorDescription: String? {
        switch self {
        case .missingAmneziaKey:
            return "Connect from Real Ai Router after saving an Amnezia Premium vpn:// key or importing an AmneziaWG .conf in Settings."
        case .invalidAmneziaConfig:
            return "The saved Amnezia Premium key could not be decoded into a tunnel configuration."
        case .invalidWireGuardConfig(let message):
            return "The Amnezia config is missing required WireGuard fields: \(message)."
        case .adapterStartFailed(let message):
            return "AmneziaWG adapter failed to start: \(message)."
        case .singBoxRuntimeMissing:
            return "Shadowrocket VLESS/Reality profiles require the sing-box Packet Tunnel runtime. Import works, but libbox.xcframework is not bundled yet."
        }
    }
}

private func isCIDRLikeRoute(_ value: String) -> Bool {
    value.contains("/") || IPv4CIDR(value) != nil || value.contains(":")
}

private func loadBundledCIDRs(resource: String, extension fileExtension: String) -> [String] {
    guard let url = Bundle.main.url(forResource: resource, withExtension: fileExtension),
          let content = try? String(contentsOf: url, encoding: .utf8) else {
        packetTunnelLogger.error("Missing bundled routing resource: \(resource).\(fileExtension)")
        return []
    }

    return content
        .split(whereSeparator: \.isNewline)
        .map { line in
            line
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init) ?? ""
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private func subtract(forceHostRoutes: [String], from cidrs: [String]) -> [String] {
    let forcedHosts = forceHostRoutes.compactMap(IPv4CIDR.init(hostRoute:))
    guard !forcedHosts.isEmpty else {
        return cidrs
    }

    return cidrs.flatMap { cidr -> [String] in
        guard let range = IPv4CIDR(cidr) else {
            return [cidr]
        }

        return forcedHosts.reduce([range]) { ranges, forcedHost in
            ranges.flatMap { $0.subtracting(host: forcedHost) }
        }.map(\.description)
    }
}

private func localRouteExcludes(
    localNetworkAccessEnabled: Bool,
    ipv6LeakProtectionEnabled: Bool
) -> [String] {
    guard localNetworkAccessEnabled else {
        return []
    }

    let ipv4LocalRanges = [
        "127.0.0.0/8",
        "10.0.0.0/8",
        "100.64.0.0/10",
        "169.254.0.0/16",
        "172.16.0.0/12",
        "192.168.0.0/16"
    ]

    guard !ipv6LeakProtectionEnabled else {
        return ipv4LocalRanges
    }

    return ipv4LocalRanges + [
        "::1/128",
        "fc00::/7",
        "fe80::/10"
    ]
}

#if !SINGBOX_TUNNEL
private extension AmneziaWireGuardConfig {
    func makeTunnelConfiguration(
        named name: String,
        routingExceptions: RoutingExceptionCollection,
        killSwitchEnabled: Bool,
        localNetworkAccessEnabled: Bool,
        ipv6LeakProtectionEnabled: Bool
    ) throws -> TunnelConfiguration {
        guard let privateKey = PrivateKey(base64Key: privateKey) else {
            throw PacketTunnelProviderError.invalidWireGuardConfig("invalid private key")
        }

        guard let publicKey = PublicKey(base64Key: publicKey) else {
            throw PacketTunnelProviderError.invalidWireGuardConfig("invalid peer public key")
        }

        guard let endpoint = Endpoint(from: endpoint) else {
            throw PacketTunnelProviderError.invalidWireGuardConfig("invalid endpoint")
        }

        var interface = InterfaceConfiguration(privateKey: privateKey)
        interface.addresses = parseCommaList(address).compactMap(IPAddressRange.init(from:))
        interface.dns = parseCommaList(dns).compactMap(DNSServer.init(from:))
        interface.killSwitchEnabled = killSwitchEnabled
        interface.mtu = mtu.flatMap(UInt16.init(exactly:))
        interface.junkPacketCount = parseUInt16(jc)
        interface.junkPacketMinSize = parseUInt16(jmin)
        interface.junkPacketMaxSize = parseUInt16(jmax)
        interface.initPacketJunkSize = parseUInt16(s1)
        interface.responsePacketJunkSize = parseUInt16(s2)
        interface.cookieReplyPacketJunkSize = parseUInt16(s3)
        interface.transportPacketJunkSize = parseUInt16(s4)
        interface.initPacketMagicHeader = h1
        interface.responsePacketMagicHeader = h2
        interface.underloadPacketMagicHeader = h3
        interface.transportPacketMagicHeader = h4
        interface.specialJunk1 = i1
        interface.specialJunk2 = i2
        interface.specialJunk3 = i3
        interface.specialJunk4 = i4
        interface.specialJunk5 = i5

        var peer = PeerConfiguration(publicKey: publicKey)
        if let presharedKey {
            guard let preSharedKey = PreSharedKey(base64Key: presharedKey) else {
                throw PacketTunnelProviderError.invalidWireGuardConfig("invalid preshared key")
            }
            peer.preSharedKey = preSharedKey
        }
        peer.endpoint = endpoint
        peer.allowedIPs = parseCommaList(allowedIPs).compactMap(IPAddressRange.init(from:))
        if peer.allowedIPs.contains(where: \.isDefaultRoute) {
            let compiledRules = RoutingExceptionCompiler.compile(routingExceptions.enabledRules)
            let forceHostRoutes = compiledRules.forceVPN.filter(\.isHostRoute)
            peer.allowedIPs.append(contentsOf: compiledRules.forceVPN)
            peer.excludeIPs = splitTunnelBypassRanges(
                excludingForceHostRoutes: forceHostRoutes,
                localNetworkAccessEnabled: localNetworkAccessEnabled,
                ipv6LeakProtectionEnabled: ipv6LeakProtectionEnabled
            )
            peer.excludeIPs.append(contentsOf: compiledRules.bypassVPN)
        }
        peer.persistentKeepAlive = persistentKeepalive.flatMap(UInt16.init(exactly:))

        guard !interface.addresses.isEmpty else {
            throw PacketTunnelProviderError.invalidWireGuardConfig("missing interface address")
        }

        guard !peer.allowedIPs.isEmpty else {
            throw PacketTunnelProviderError.invalidWireGuardConfig("missing allowed IPs")
        }

        return TunnelConfiguration(name: name, interface: interface, peers: [peer])
    }

    private func parseCommaList(_ value: String?) -> [String] {
        guard let value else {
            return []
        }

        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func parseUInt16(_ value: String?) -> UInt16? {
        guard let value else {
            return nil
        }

        return UInt16(value)
    }

    private func splitTunnelBypassRanges(
        excludingForceHostRoutes forceHostRoutes: [IPAddressRange],
        localNetworkAccessEnabled: Bool,
        ipv6LeakProtectionEnabled: Bool
    ) -> [IPAddressRange] {
        let localProviderRanges = localRouteExcludes(
            localNetworkAccessEnabled: localNetworkAccessEnabled,
            ipv6LeakProtectionEnabled: ipv6LeakProtectionEnabled
        )
        let ruRanges = subtract(
            forceHostRoutes: forceHostRoutes.map(\.stringRepresentation),
            from: loadBundledCIDRs(resource: "ru-aggregated", extension: "zone")
        )
        packetTunnelLogger.info("Applying split tunnel bypass ranges: local=\(localProviderRanges.count, privacy: .public) ru=\(ruRanges.count, privacy: .public)")

        return (localProviderRanges + ruRanges).compactMap(IPAddressRange.init(from:))
    }

}

private extension IPAddressRange {
    var isDefaultRoute: Bool {
        stringRepresentation == "0.0.0.0/0" || stringRepresentation == "::/0"
    }

    var isHostRoute: Bool {
        stringRepresentation.hasSuffix("/32") || stringRepresentation.hasSuffix("/128")
    }
}

private enum RoutingExceptionCompiler {
    static func compile(_ rules: [RoutingExceptionRule]) -> (forceVPN: [IPAddressRange], bypassVPN: [IPAddressRange]) {
        var forceVPN: [IPAddressRange] = []
        var bypassVPN: [IPAddressRange] = []

        for rule in rules {
            let ranges = ranges(for: rule.value)
            switch rule.mode {
            case .forceVPN:
                forceVPN.append(contentsOf: ranges)
            case .bypassVPN:
                bypassVPN.append(contentsOf: ranges)
            }
        }

        return (forceVPN.uniqued(), bypassVPN.uniqued())
    }

    private static func ranges(for value: String) -> [IPAddressRange] {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .split(separator: "/")
            .first
            .map(String.init) ?? ""

        guard !normalized.isEmpty else {
            return []
        }

        if normalized.contains("/") || IPv4CIDR(normalized) != nil || IPv6Address(normalized) != nil {
            return IPAddressRange(from: normalized).map { [$0] } ?? []
        }

        let host = normalized.hasPrefix("*.") ? String(normalized.dropFirst(2)) : normalized
        return resolveHostRoutes(host: host)
    }

    private static func resolveHostRoutes(host: String) -> [IPAddressRange] {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else {
            return []
        }
        defer { freeaddrinfo(result) }

        var ranges: [IPAddressRange] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let info = cursor {
            if info.pointee.ai_family == AF_INET {
                var address = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    ranges.append(contentsOf: IPAddressRange(from: "\(String(cString: buffer))/32").map { [$0] } ?? [])
                }
            } else if info.pointee.ai_family == AF_INET6 {
                var address = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
                    ranges.append(contentsOf: IPAddressRange(from: "\(String(cString: buffer))/128").map { [$0] } ?? [])
                }
            }
            cursor = info.pointee.ai_next
        }

        return ranges.uniqued()
    }
}

private extension Array where Element == IPAddressRange {
    func uniqued() -> [IPAddressRange] {
        var seen = Set<String>()
        return filter { seen.insert($0.stringRepresentation).inserted }
    }
}
#endif

private struct IPv4CIDR: CustomStringConvertible {
    let base: UInt32
    let prefix: UInt8

    init?(_ raw: String) {
        let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
        guard let address = Self.parse(parts[0]) else {
            return nil
        }

        let parsedPrefix = parts.dropFirst().first.flatMap(UInt8.init) ?? 32
        prefix = min(parsedPrefix, 32)
        base = address & Self.mask(prefix)
    }

    init?(hostRoute raw: String) {
        let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              parts[1] == "32",
              let address = Self.parse(parts[0]) else {
            return nil
        }

        base = address
        prefix = 32
    }

#if !SINGBOX_TUNNEL
    init?(hostRoute range: IPAddressRange) {
        self.init(hostRoute: range.stringRepresentation)
    }
#endif

    private init(base: UInt32, prefix: UInt8) {
        self.base = base & Self.mask(prefix)
        self.prefix = prefix
    }

    var description: String {
        "\(Self.format(base))/\(prefix)"
    }

    func subtracting(host: IPv4CIDR) -> [IPv4CIDR] {
        guard host.prefix == 32, contains(host.base), prefix < 32 else {
            return host.prefix == 32 && host.base == base ? [] : [self]
        }

        let nextPrefix = prefix + 1
        let halfSize = UInt32(1) << (32 - nextPrefix)
        let lower = IPv4CIDR(base: base, prefix: nextPrefix)
        let upper = IPv4CIDR(base: base + halfSize, prefix: nextPrefix)
        return lower.subtracting(host: host) + upper.subtracting(host: host)
    }

    private func contains(_ address: UInt32) -> Bool {
        (address & Self.mask(prefix)) == base
    }

    private static func mask(_ prefix: UInt8) -> UInt32 {
        prefix == 0 ? 0 : UInt32.max << (32 - UInt32(prefix))
    }

    private static func parse(_ raw: String) -> UInt32? {
        guard let address = IPv4Address(raw) else {
            return nil
        }

        return address.rawValue.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func format(_ value: UInt32) -> String {
        [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        .map(String.init)
        .joined(separator: ".")
    }
}
