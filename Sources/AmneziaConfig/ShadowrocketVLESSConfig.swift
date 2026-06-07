import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum ShadowrocketVLESSConfigError: LocalizedError, Equatable {
    case invalidJSON
    case unsupportedType(String)
    case missingHost
    case missingPort
    case missingUUID
    case missingRealityPublicKey
    case missingSubscriptionURL
    case noSupportedProfiles

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Shadowrocket profile is not valid JSON."
        case .unsupportedType(let type):
            return "Only Shadowrocket VLESS profiles are supported for sing-box import. Found: \(type)."
        case .missingHost:
            return "Shadowrocket VLESS profile does not contain a server host."
        case .missingPort:
            return "Shadowrocket VLESS profile does not contain a server port."
        case .missingUUID:
            return "Shadowrocket VLESS profile does not contain a user UUID."
        case .missingRealityPublicKey:
            return "Shadowrocket VLESS/Reality profile does not contain a public key."
        case .missingSubscriptionURL:
            return "Shadowrocket subscription JSON does not contain a subscription URL."
        case .noSupportedProfiles:
            return "The subscription does not contain supported VLESS/Reality profiles."
        }
    }
}

public struct ShadowrocketVLESSConfig: Codable, Equatable, Sendable {
    public var title: String
    public var regionCode: String?
    public var host: String
    public var port: UInt16
    public var uuid: String
    public var peer: String?
    public var publicKey: String
    public var shortID: String?
    public var flow: String?
    public var fingerprint: String?
    public var spiderX: String?
    public var udp: Bool

    public var endpoint: String {
        "\(host):\(port)"
    }

    public var redactedSummary: String {
        let titleText = title.isEmpty ? "VLESS Reality" : title
        return "\(titleText) endpoint=\(endpoint) sni=\(peer ?? "unset")"
    }
}

public struct SingBoxConfig: Codable, Equatable, Sendable {
    public var jsonString: String
}

public struct SingBoxRouteOverrides: Equatable, Sendable {
    public static let providerDNSServers = ["77.88.8.88", "77.88.8.2"]
    public static let providerDNSDomainSuffixes = [
        "ru",
        "local",
        "lan",
        "localhost",
        "in-addr.arpa",
        "ip6.arpa"
    ]

    public var forceVPNDomainSuffixes: [String]
    public var bypassVPNDomainSuffixes: [String]
    public var forceVPNIPCIDRs: [String]
    public var bypassVPNIPCIDRs: [String]
    public var systemRouteExcludeIPCIDRs: [String]

    public init(
        forceVPNDomainSuffixes: [String] = [],
        bypassVPNDomainSuffixes: [String] = [],
        forceVPNIPCIDRs: [String] = [],
        bypassVPNIPCIDRs: [String] = [],
        systemRouteExcludeIPCIDRs: [String] = []
    ) {
        self.forceVPNDomainSuffixes = forceVPNDomainSuffixes
        self.bypassVPNDomainSuffixes = bypassVPNDomainSuffixes
        self.forceVPNIPCIDRs = forceVPNIPCIDRs
        self.bypassVPNIPCIDRs = bypassVPNIPCIDRs
        self.systemRouteExcludeIPCIDRs = systemRouteExcludeIPCIDRs
    }
}

public struct ShadowrocketVLESSProfileEntry: Equatable, Sendable {
    public var profile: ShadowrocketVLESSConfig
    public var rawConfig: String

    public init(profile: ShadowrocketVLESSConfig, rawConfig: String) {
        self.profile = profile
        self.rawConfig = rawConfig
    }
}

public struct ShadowrocketVLESSConfigParser: Sendable {
    public init() {}

    public func parse(_ payload: Data) throws -> ShadowrocketVLESSConfig {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: payload)
        } catch {
            throw ShadowrocketVLESSConfigError.invalidJSON
        }

        guard let object = json as? [String: Any] else {
            throw ShadowrocketVLESSConfigError.invalidJSON
        }

        return try parse(object)
    }

    public func parseEntries(_ text: String) throws -> [ShadowrocketVLESSProfileEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw ShadowrocketVLESSConfigError.invalidJSON
        }

        if let direct = try? parse(trimmed) {
            return [ShadowrocketVLESSProfileEntry(profile: direct, rawConfig: trimmed)]
        }

        if let vless = try? parseVLESSURL(trimmed) {
            return [ShadowrocketVLESSProfileEntry(profile: vless, rawConfig: trimmed)]
        }

        let expanded = decodedSubscriptionText(from: trimmed) ?? trimmed
        let entries = expanded
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { line -> ShadowrocketVLESSProfileEntry? in
                guard line.localizedCaseInsensitiveContains("vless://"),
                      let profile = try? parseVLESSURL(line) else {
                    return nil
                }
                return ShadowrocketVLESSProfileEntry(profile: profile, rawConfig: line)
            }

        if entries.isEmpty {
            throw ShadowrocketVLESSConfigError.noSupportedProfiles
        }

        return entries
    }

    public func subscriptionURL(from text: String) throws -> URL? {
        let data = Data(text.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any] else {
            return nil
        }

        let type = stringValue("type", in: object) ?? ""
        guard type.caseInsensitiveCompare("Subscribe") == .orderedSame else {
            return nil
        }

        for key in ["host", "url", "link"] {
            if let rawURL = stringValue(key, in: object),
               let url = URL(string: rawURL),
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                return url
            }
        }

        throw ShadowrocketVLESSConfigError.missingSubscriptionURL
    }

    public func parse(_ text: String) throws -> ShadowrocketVLESSConfig {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveContains("vless://"),
           let profile = try? parseVLESSURL(trimmed) {
            return profile
        }

        return try parse(Data(trimmed.utf8))
    }

    private func parse(_ object: [String: Any]) throws -> ShadowrocketVLESSConfig {
        let type = stringValue("type", in: object) ?? ""
        guard type.caseInsensitiveCompare("VLESS") == .orderedSame else {
            throw ShadowrocketVLESSConfigError.unsupportedType(type.isEmpty ? "unknown" : type)
        }

        guard let host = stringValue("host", in: object), !host.isEmpty else {
            throw ShadowrocketVLESSConfigError.missingHost
        }

        guard let portString = stringValue("port", in: object), let port = UInt16(portString) else {
            throw ShadowrocketVLESSConfigError.missingPort
        }

        guard let uuid = stringValue("password", in: object), !uuid.isEmpty else {
            throw ShadowrocketVLESSConfigError.missingUUID
        }

        guard let publicKey = stringValue("publicKey", in: object), !publicKey.isEmpty else {
            throw ShadowrocketVLESSConfigError.missingRealityPublicKey
        }

        let xtls = intValue("xtls", in: object)
        return ShadowrocketVLESSConfig(
            title: stringValue("title", in: object) ?? "VLESS Reality",
            regionCode: stringValue("flag", in: object)?.uppercased(),
            host: host,
            port: port,
            uuid: uuid,
            peer: stringValue("peer", in: object),
            publicKey: publicKey,
            shortID: stringValue("shortId", in: object),
            flow: xtls == 2 ? "xtls-rprx-vision" : nil,
            fingerprint: stringValue("fp", in: object),
            spiderX: stringValue("spx", in: object),
            udp: intValue("udp", in: object).map { $0 != 0 } ?? true
        )
    }

    private func parseVLESSURL(_ text: String) throws -> ShadowrocketVLESSConfig {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.caseInsensitiveCompare("vless") == .orderedSame else {
            throw ShadowrocketVLESSConfigError.invalidJSON
        }

        guard let host = components.host, !host.isEmpty else {
            throw ShadowrocketVLESSConfigError.missingHost
        }

        guard let port = components.port, let portValue = UInt16(exactly: port) else {
            throw ShadowrocketVLESSConfigError.missingPort
        }

        guard let uuid = components.user, !uuid.isEmpty else {
            throw ShadowrocketVLESSConfigError.missingUUID
        }

        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name.lowercased(), ($0.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            }
        )
        guard let publicKey = firstNonEmpty(query["pbk"], query["publickey"], query["public_key"]) else {
            throw ShadowrocketVLESSConfigError.missingRealityPublicKey
        }

        let title = components.fragment?.removingPercentEncoding ?? "VLESS Reality"
        let peer = firstNonEmpty(query["sni"], query["peer"], query["servername"], query["server_name"])
        let shortID = firstNonEmpty(query["sid"], query["shortid"], query["short_id"])
        let flow = firstNonEmpty(query["flow"])
        let fingerprint = firstNonEmpty(query["fp"], query["fingerprint"])
        let spiderX = firstNonEmpty(query["spx"], query["spiderx"], query["spider_x"])

        return ShadowrocketVLESSConfig(
            title: title.isEmpty ? "VLESS Reality" : title,
            regionCode: nil,
            host: host,
            port: portValue,
            uuid: uuid.removingPercentEncoding ?? uuid,
            peer: peer,
            publicKey: publicKey,
            shortID: shortID,
            flow: flow,
            fingerprint: fingerprint,
            spiderX: spiderX,
            udp: true
        )
    }

    private func decodedSubscriptionText(from text: String) -> String? {
        let compact = text
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard !compact.isEmpty else {
            return nil
        }

        var padded = compact
        let remainder = padded.count % 4
        if remainder != 0 {
            padded += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: padded, options: [.ignoreUnknownCharacters]),
              let decoded = String(data: data, encoding: .utf8),
              decoded.localizedCaseInsensitiveContains("://") else {
            return nil
        }

        return decoded
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        values.first { value in
            guard let value else {
                return false
            }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? nil
    }

    private func stringValue(_ key: String, in object: [String: Any]) -> String? {
        if let value = object[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let value = object[key] as? NSNumber {
            return value.stringValue
        }

        return nil
    }

    private func intValue(_ key: String, in object: [String: Any]) -> Int? {
        if let value = object[key] as? Int {
            return value
        }

        if let value = object[key] as? NSNumber {
            return value.intValue
        }

        if let value = object[key] as? String {
            return Int(value)
        }

        return nil
    }
}

public struct SingBoxConfigBuilder: Sendable {
    public init() {}

    public func build(
        from profile: ShadowrocketVLESSConfig,
        routeOverrides: SingBoxRouteOverrides = SingBoxRouteOverrides(),
        dnsProtectionEnabled: Bool = true
    ) throws -> SingBoxConfig {
        var outbound: [String: Any] = [
            "type": "vless",
            "tag": "proxy",
            "server": profile.host,
            "server_port": Int(profile.port),
            "uuid": profile.uuid,
            "packet_encoding": "xudp",
            "tls": [
                "enabled": true,
                "server_name": profile.peer ?? profile.host,
                "utls": [
                    "enabled": true,
                    "fingerprint": profile.fingerprint ?? "chrome"
                ],
                "reality": [
                    "enabled": true,
                    "public_key": profile.publicKey,
                    "short_id": profile.shortID ?? ""
                ]
            ] as [String: Any]
        ]
        if let flow = profile.flow {
            outbound["flow"] = flow
        }

        var routeRules: [[String: Any]] = [
            [
                "inbound": "tun-in",
                "action": "sniff"
            ]
        ]
        let forceVPNDomainSuffixes = routeOverrides.forceVPNDomainSuffixes
            .map(normalizedDomainSuffix)
            .filter { !$0.isEmpty }
            .uniqued()
        appendRouteRules(
            to: &routeRules,
            domainSuffixes: forceVPNDomainSuffixes,
            ipCIDRs: routeOverrides.forceVPNIPCIDRs,
            outbound: "proxy"
        )
        appendRouteRules(
            to: &routeRules,
            domainSuffixes: ["ru"] + routeOverrides.bypassVPNDomainSuffixes,
            ipCIDRs: [
                "10.0.0.0/8",
                "100.64.0.0/10",
                "169.254.0.0/16",
                "172.16.0.0/12",
                "192.168.0.0/16",
                "77.88.8.88/32",
                "77.88.8.2/32",
                "fc00::/7",
                "fe80::/10"
            ] + routeOverrides.bypassVPNIPCIDRs,
            outbound: "direct"
        )

        var tunInbound: [String: Any] = [
            "type": "tun",
            "tag": "tun-in",
            "interface_name": "real-ai-vpn",
            "address": [
                "172.19.0.1/30"
            ],
            "auto_route": true,
            "strict_route": false,
            "stack": "system"
        ]

        let routeExcludeAddresses = routeOverrides.systemRouteExcludeIPCIDRs
            .compactMap(normalizedIPPrefix)
            .uniqued()
        if !routeExcludeAddresses.isEmpty {
            tunInbound["route_exclude_address"] = routeExcludeAddresses
        }

        let root: [String: Any] = [
            "log": [
                "level": "warn",
                "timestamp": true
            ],
            "dns": dnsConfiguration(routeOverrides: routeOverrides, dnsProtectionEnabled: dnsProtectionEnabled),
            "inbounds": [
                tunInbound
            ],
            "outbounds": [
                outbound,
                [
                    "type": "direct",
                    "tag": "direct"
                ]
            ],
            "route": [
                "auto_detect_interface": true,
                "rules": routeRules,
                "final": "proxy"
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return SingBoxConfig(jsonString: String(decoding: data, as: UTF8.self))
    }

    private func dnsConfiguration(
        routeOverrides: SingBoxRouteOverrides,
        dnsProtectionEnabled: Bool
    ) -> [String: Any] {
        var servers: [[String: Any]] = [
            [
                "tag": "cloudflare",
                "type": "tls",
                "server": "1.1.1.1",
                "server_port": 853,
                "detour": "proxy"
            ]
        ]

        guard dnsProtectionEnabled else {
            return [
                "servers": servers,
                "final": "cloudflare"
            ]
        }

        servers.append([
            "tag": "provider-yandex",
            "type": "udp",
            "server": SingBoxRouteOverrides.providerDNSServers[0]
        ])
        servers.append([
            "tag": "provider-yandex-backup",
            "type": "udp",
            "server": SingBoxRouteOverrides.providerDNSServers[1]
        ])

        let forceVPNSuffixes = routeOverrides.forceVPNDomainSuffixes
            .map(normalizedDomainSuffix)
            .filter { !$0.isEmpty }
            .uniqued()
        let providerSuffixes = (SingBoxRouteOverrides.providerDNSDomainSuffixes + routeOverrides.bypassVPNDomainSuffixes)
            .map(normalizedDomainSuffix)
            .filter { !$0.isEmpty && !forceVPNSuffixes.contains($0) }
            .uniqued()

        var rules: [[String: Any]] = []
        if !forceVPNSuffixes.isEmpty {
            rules.append([
                "domain_suffix": forceVPNSuffixes,
                "server": "cloudflare"
            ])
        }
        if !providerSuffixes.isEmpty {
            rules.append([
                "domain_suffix": providerSuffixes,
                "server": "provider-yandex"
            ])
        }

        return [
            "servers": servers,
            "rules": rules,
            "final": "cloudflare"
        ]
    }

    private func appendRouteRules(
        to rules: inout [[String: Any]],
        domainSuffixes: [String],
        ipCIDRs: [String],
        outbound: String
    ) {
        let normalizedDomainSuffixes = domainSuffixes
            .map(normalizedDomainSuffix)
            .filter { !$0.isEmpty }
            .uniqued()
        if !normalizedDomainSuffixes.isEmpty {
            rules.append([
                "domain_suffix": normalizedDomainSuffixes,
                "outbound": outbound
            ])
        }

        let normalizedIPCIDRs = ipCIDRs
            .compactMap(normalizedIPPrefix)
            .uniqued()
        if !normalizedIPCIDRs.isEmpty {
            rules.append([
                "ip_cidr": normalizedIPCIDRs,
                "outbound": outbound
            ])
        }
    }

    private func normalizedIPPrefix(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }
        if normalized.contains("/") {
            return normalized
        }

        var ipv4 = in_addr()
        if inet_pton(AF_INET, normalized, &ipv4) == 1 {
            return "\(normalized)/32"
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, normalized, &ipv6) == 1 {
            return "\(normalized)/128"
        }

        return nil
    }

    private func normalizedDomainSuffix(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .split(separator: "/")
            .first
            .map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "*."))
            ?? ""
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
