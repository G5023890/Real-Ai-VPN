import AmneziaConfig
import Foundation
import NetworkExtension
import os
import WireGuardKit

private let packetTunnelLogger = Logger(
    subsystem: "com.codex.RealAiVPN.PacketTunnel",
    category: "PacketTunnelProvider"
)

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let decoder = AmneziaConfigDecoder()
    private lazy var adapter = WireGuardAdapter(with: self) { logLevel, message in
        switch logLevel {
        case .verbose:
            packetTunnelLogger.debug("\(message, privacy: .public)")
        case .error:
            packetTunnelLogger.error("\(message, privacy: .public)")
        }
    }

    override func startTunnel(options: [String: NSObject]?) async throws {
        packetTunnelLogger.info("Starting Amnezia packet tunnel")

        let importedConfig = (options?["amneziaVPNURL"] as? String) ?? (options?["amneziaVPNURL"] as? NSString).map(String.init)

        guard let importedConfig, !importedConfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            packetTunnelLogger.error("Missing transient Amnezia config")
            throw PacketTunnelProviderError.missingAmneziaKey
        }

        let config: AmneziaWireGuardConfig
        do {
            config = try decoder.decodeImportedWireGuardConfig(from: importedConfig)
            packetTunnelLogger.info("Decoded Amnezia config: \(config.redactedSummary, privacy: .public)")
        } catch {
            packetTunnelLogger.error("Failed to decode Amnezia config: \(error.localizedDescription, privacy: .public)")
            throw PacketTunnelProviderError.invalidAmneziaConfig
        }

        try await startAmneziaWireGuardTunnel(with: config)
    }

    private func startAmneziaWireGuardTunnel(with config: AmneziaWireGuardConfig) async throws {
        let tunnelConfiguration = try config.makeTunnelConfiguration(named: "Real Ai VPN")

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
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        packetTunnelLogger.info("Stopping packet tunnel, reason: \(reason.rawValue)")
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
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        "ok".data(using: .utf8)
    }
}

private enum PacketTunnelProviderError: LocalizedError {
    case missingAmneziaKey
    case invalidAmneziaConfig
    case invalidWireGuardConfig(String)
    case adapterStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAmneziaKey:
            return "Connect from Real Ai VPN after saving an Amnezia Premium vpn:// key or importing an AmneziaWG .conf in Settings."
        case .invalidAmneziaConfig:
            return "The saved Amnezia Premium key could not be decoded into a tunnel configuration."
        case .invalidWireGuardConfig(let message):
            return "The Amnezia config is missing required WireGuard fields: \(message)."
        case .adapterStartFailed(let message):
            return "AmneziaWG adapter failed to start: \(message)."
        }
    }
}

private extension AmneziaWireGuardConfig {
    func makeTunnelConfiguration(named name: String) throws -> TunnelConfiguration {
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
            peer.excludeIPs = splitTunnelBypassRanges()
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

    private func splitTunnelBypassRanges() -> [IPAddressRange] {
        let localProviderRanges = [
            // Local/provider networks must never hairpin through the VPN tunnel.
            "10.0.0.0/8",
            "100.64.0.0/10",
            "127.0.0.0/8",
            "169.254.0.0/16",
            "172.16.0.0/12",
            "192.168.0.0/16",
            "224.0.0.0/4"
        ]

        let ruRanges = loadBundledCIDRs(resource: "ru-aggregated", extension: "zone")
        packetTunnelLogger.info("Applying split tunnel bypass ranges: local=\(localProviderRanges.count, privacy: .public) ru=\(ruRanges.count, privacy: .public)")

        return (localProviderRanges + ruRanges).compactMap(IPAddressRange.init(from:))
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
}

private extension IPAddressRange {
    var isDefaultRoute: Bool {
        stringRepresentation == "0.0.0.0/0" || stringRepresentation == "::/0"
    }
}
