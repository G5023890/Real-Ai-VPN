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
        "ru"
    ]
    public static let localDiscoveryDomainSuffixes = [
        "local",
        "lan",
        "localhost",
        "in-addr.arpa",
        "ip6.arpa"
    ]
    public static let googleProtectedDomainSuffixes = [
        "google.com",
        "googleapis.com",
        "gstatic.com",
        "googleusercontent.com",
        "gmail.com",
        "googlemail.com",
        "ggpht.com",
        "googlevideo.com",
        "gvt1.com",
        "gvt2.com",
        "gvt3.com",
        "youtube.com",
        "ytimg.com"
    ]
    public static let appleAuthProtectedDomainSuffixes = [
        "apple.com",
        "icloud.com",
        "icloud.com.cn",
        "mzstatic.com",
        "itunes.com",
        "appstore.com",
        "cdn-apple.com",
        "aaplimg.com",
        "apple-cloudkit.com",
        "icloud-content.com",
        "me.com",
        "mac.com"
    ]
    public static let authCompatibilityDomainSuffixes = googleProtectedDomainSuffixes + appleAuthProtectedDomainSuffixes
    public static let yandexMapsCompatibilityDomainSuffixes = [
        "yandex.ru",
        "yandex.net",
        "yastatic.net",
        "yandex.st",
        "maps.yandex.ru",
        "maps.yandex.net",
        "api-maps.yandex.ru",
        "static-maps.yandex.ru",
        "geocode-maps.yandex.ru",
        "suggest-maps.yandex.ru",
        "mobile.maps.yandex.net",
        "mobile.yandex.net",
        "mobile.yandex.ru",
        "core-renderer-tiles.maps.yandex.net",
        "vec.maps.yandex.net",
        "sat.maps.yandex.net",
        "yandexnavi.ru",
        "yandexcloud.net"
    ]
    public static let legacyMailCompatibilityPorts = [
        25,
        110,
        143,
        465,
        585,
        587,
        993,
        995
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let directURL = URL(string: trimmed),
           ["http", "https"].contains(directURL.scheme?.lowercased() ?? "") {
            return directURL
        }

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
        if object["outbounds"] != nil {
            return try parseXrayVLESSConfiguration(object)
        }

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

    /// Imports the VLESS outbound from an Xray configuration file.  Local DNS,
    /// inbounds and routing are intentionally not imported: those are supplied
    /// by the packet tunnel so iOS can manage the VPN interface safely.
    private func parseXrayVLESSConfiguration(_ object: [String: Any]) throws -> ShadowrocketVLESSConfig {
        guard let outbounds = object["outbounds"] as? [[String: Any]],
              let outbound = outbounds.first(where: {
                  (stringValue("protocol", in: $0) ?? "").caseInsensitiveCompare("vless") == .orderedSame
              }) else {
            throw ShadowrocketVLESSConfigError.unsupportedType("Xray configuration without VLESS outbound")
        }

        guard let settings = outbound["settings"] as? [String: Any],
              let vnext = settings["vnext"] as? [[String: Any]],
              let server = vnext.first else {
            throw ShadowrocketVLESSConfigError.missingHost
        }

        guard let host = stringValue("address", in: server), !host.isEmpty else {
            throw ShadowrocketVLESSConfigError.missingHost
        }
        guard let portString = stringValue("port", in: server), let port = UInt16(portString) else {
            throw ShadowrocketVLESSConfigError.missingPort
        }
        guard let users = server["users"] as? [[String: Any]],
              let user = users.first,
              let uuid = stringValue("id", in: user), !uuid.isEmpty else {
            throw ShadowrocketVLESSConfigError.missingUUID
        }

        let streamSettings = outbound["streamSettings"] as? [String: Any] ?? [:]
        let realitySettings = streamSettings["realitySettings"] as? [String: Any] ?? [:]
        guard let publicKey = stringValue("publicKey", in: realitySettings), !publicKey.isEmpty else {
            throw ShadowrocketVLESSConfigError.missingRealityPublicKey
        }

        let shortID = firstNonEmpty(
            stringValue("shortId", in: realitySettings),
            (realitySettings["shortIds"] as? [String])?.first
        )
        return ShadowrocketVLESSConfig(
            title: stringValue("remarks", in: object) ?? stringValue("tag", in: outbound) ?? "VLESS Reality",
            regionCode: nil,
            host: host,
            port: port,
            uuid: uuid,
            peer: stringValue("serverName", in: realitySettings),
            publicKey: publicKey,
            shortID: shortID,
            flow: stringValue("flow", in: user),
            fingerprint: stringValue("fingerprint", in: realitySettings),
            spiderX: stringValue("spiderX", in: realitySettings),
            udp: true
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
        dnsProtectionEnabled: Bool = true,
        ipv4OnlyCompatibilityEnabled: Bool = false
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
        let forceVPNDomainSuffixes = (
            SingBoxRouteOverrides.authCompatibilityDomainSuffixes
                + SingBoxRouteOverrides.yandexMapsCompatibilityDomainSuffixes
                + routeOverrides.forceVPNDomainSuffixes
        )
            .map(normalizedDomainSuffix)
            .filter { !$0.isEmpty }
            .uniqued()
        appendYandexMapsQUICCompatibilityRule(to: &routeRules)
        appendQUICFallbackRule(to: &routeRules)
        appendLegacyMailCompatibilityRule(to: &routeRules)
        appendRouteRules(
            to: &routeRules,
            domainSuffixes: forceVPNDomainSuffixes,
            ipCIDRs: routeOverrides.forceVPNIPCIDRs,
            outbound: "proxy"
        )
        let directDomainSuffixes = (["ru"] + SingBoxRouteOverrides.localDiscoveryDomainSuffixes + routeOverrides.bypassVPNDomainSuffixes)
            .map(normalizedDomainSuffix)
            .filter { suffix in
                !suffix.isEmpty && !forceVPNDomainSuffixes.contains(suffix)
            }
            .uniqued()
        appendRouteRules(
            to: &routeRules,
            domainSuffixes: directDomainSuffixes,
            ipCIDRs: [
                "10.0.0.0/8",
                "100.64.0.0/10",
                "169.254.0.0/16",
                "172.16.0.0/12",
                "192.168.0.0/16",
                "224.0.0.0/4",
                "255.255.255.255/32",
                "77.88.8.88/32",
                "77.88.8.2/32",
                "fc00::/7",
                "fe80::/10",
                "ff00::/8"
            ] + routeOverrides.bypassVPNIPCIDRs,
            outbound: "direct"
        )

        let tunAddresses = ipv4OnlyCompatibilityEnabled
            ? ["172.19.0.1/30"]
            : [
                "172.19.0.1/30",
                "fdfe:dcba:9876::1/126"
            ]

        var tunInbound: [String: Any] = [
            "type": "tun",
            "tag": "tun-in",
            "interface_name": "real-ai-vpn",
            "address": tunAddresses,
            "auto_route": true,
            "strict_route": false,
            "stack": "gvisor"
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
            "dns": dnsConfiguration(
                routeOverrides: routeOverrides,
                dnsProtectionEnabled: dnsProtectionEnabled,
                ipv4OnlyCompatibilityEnabled: ipv4OnlyCompatibilityEnabled
            ),
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
        dnsProtectionEnabled: Bool,
        ipv4OnlyCompatibilityEnabled: Bool
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
            var dns: [String: Any] = [
                "servers": servers,
                "final": "cloudflare"
            ]
            if ipv4OnlyCompatibilityEnabled {
                dns["strategy"] = "ipv4_only"
            }
            return dns
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

        let yandexMapsForceVPNSuffixes = SingBoxRouteOverrides.yandexMapsCompatibilityDomainSuffixes
            .map(normalizedDomainSuffix)
            .filter { !$0.isEmpty }
            .uniqued()
        let forceVPNSuffixes = (
            SingBoxRouteOverrides.authCompatibilityDomainSuffixes
                + routeOverrides.forceVPNDomainSuffixes
        )
            .map(normalizedDomainSuffix)
            .filter { !$0.isEmpty }
            .filter { !yandexMapsForceVPNSuffixes.contains($0) }
            .uniqued()
        let providerSuffixes = (SingBoxRouteOverrides.providerDNSDomainSuffixes + routeOverrides.bypassVPNDomainSuffixes)
            .map(normalizedDomainSuffix)
            .filter { !$0.isEmpty && !forceVPNSuffixes.contains($0) && !yandexMapsForceVPNSuffixes.contains($0) && !isLocalDiscoverySuffix($0) }
            .uniqued()

        var rules: [[String: Any]] = []
        if !yandexMapsForceVPNSuffixes.isEmpty {
            var yandexMapsRule: [String: Any] = [
                "domain_suffix": yandexMapsForceVPNSuffixes,
                "server": "cloudflare",
                "strategy": "ipv4_only"
            ]
            if ipv4OnlyCompatibilityEnabled {
                yandexMapsRule["strategy"] = "ipv4_only"
            }
            rules.append(yandexMapsRule)
        }
        if !forceVPNSuffixes.isEmpty {
            var forceRule: [String: Any] = [
                "domain_suffix": forceVPNSuffixes,
                "server": "cloudflare"
            ]
            if ipv4OnlyCompatibilityEnabled {
                forceRule["strategy"] = "ipv4_only"
            }
            rules.append(forceRule)
        }
        if !providerSuffixes.isEmpty {
            var providerRule: [String: Any] = [
                "domain_suffix": providerSuffixes,
                "server": "provider-yandex"
            ]
            if ipv4OnlyCompatibilityEnabled {
                providerRule["strategy"] = "ipv4_only"
            }
            rules.append(providerRule)
        }

        var dns: [String: Any] = [
            "servers": servers,
            "rules": rules,
            "final": "cloudflare"
        ]
        if ipv4OnlyCompatibilityEnabled {
            dns["strategy"] = "ipv4_only"
        }
        return dns
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

    private func appendQUICFallbackRule(to rules: inout [[String: Any]]) {
        rules.append([
            "network": "udp",
            "port": 443,
            "action": "reject",
            "method": "default",
            "no_drop": true
        ])
    }

    private func appendYandexMapsQUICCompatibilityRule(to rules: inout [[String: Any]]) {
        rules.append([
            "network": "udp",
            "port": 443,
            "domain_suffix": SingBoxRouteOverrides.yandexMapsCompatibilityDomainSuffixes
                .map(normalizedDomainSuffix)
                .filter { !$0.isEmpty }
                .uniqued(),
            "outbound": "proxy"
        ])
    }

    private func appendLegacyMailCompatibilityRule(to rules: inout [[String: Any]]) {
        rules.append([
            "network": "tcp",
            "port": SingBoxRouteOverrides.legacyMailCompatibilityPorts,
            "outbound": "direct"
        ])
    }

    private func isLocalDiscoverySuffix(_ value: String) -> Bool {
        let suffix = normalizedDomainSuffix(value)
        guard !suffix.isEmpty else { return false }

        return SingBoxRouteOverrides.localDiscoveryDomainSuffixes.contains { localSuffix in
            suffix == localSuffix || suffix.hasSuffix(".\(localSuffix)")
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
