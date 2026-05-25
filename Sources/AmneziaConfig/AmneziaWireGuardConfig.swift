import Foundation

public enum AmneziaWireGuardConfigError: LocalizedError, Equatable {
    case invalidJSON
    case premiumSubscriptionRequiresGatewayConfig
    case missingInterfacePrivateKey
    case missingPeerPublicKey
    case missingEndpoint

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "The Amnezia payload is not a supported JSON object."
        case .premiumSubscriptionRequiresGatewayConfig:
            return "This is an Amnezia Premium subscription token. The app must fetch a device-specific AWG config from Amnezia Gateway before connecting."
        case .missingInterfacePrivateKey:
            return "The Amnezia config does not contain an interface private key."
        case .missingPeerPublicKey:
            return "The Amnezia config does not contain a peer public key."
        case .missingEndpoint:
            return "The Amnezia config does not contain a server endpoint."
        }
    }
}

public struct AmneziaWireGuardConfig: Codable, Equatable, Sendable {
    public var privateKey: String
    public var address: String?
    public var dns: String?
    public var publicKey: String
    public var presharedKey: String?
    public var endpoint: String
    public var allowedIPs: String
    public var persistentKeepalive: Int?
    public var mtu: Int?
    public var jc: String?
    public var jmin: String?
    public var jmax: String?
    public var s1: String?
    public var s2: String?
    public var h1: String?
    public var h2: String?
    public var h3: String?
    public var h4: String?
    public var s3: String?
    public var s4: String?
    public var i1: String?
    public var i2: String?
    public var i3: String?
    public var i4: String?
    public var i5: String?

    public init(
        privateKey: String,
        address: String? = nil,
        dns: String? = nil,
        publicKey: String,
        presharedKey: String? = nil,
        endpoint: String,
        allowedIPs: String = "0.0.0.0/0, ::/0",
        persistentKeepalive: Int? = 25,
        mtu: Int? = nil,
        jc: String? = nil,
        jmin: String? = nil,
        jmax: String? = nil,
        s1: String? = nil,
        s2: String? = nil,
        h1: String? = nil,
        h2: String? = nil,
        h3: String? = nil,
        h4: String? = nil,
        s3: String? = nil,
        s4: String? = nil,
        i1: String? = nil,
        i2: String? = nil,
        i3: String? = nil,
        i4: String? = nil,
        i5: String? = nil
    ) {
        self.privateKey = privateKey
        self.address = address
        self.dns = dns
        self.publicKey = publicKey
        self.presharedKey = presharedKey
        self.endpoint = endpoint
        self.allowedIPs = allowedIPs
        self.persistentKeepalive = persistentKeepalive
        self.mtu = mtu
        self.jc = jc
        self.jmin = jmin
        self.jmax = jmax
        self.s1 = s1
        self.s2 = s2
        self.h1 = h1
        self.h2 = h2
        self.h3 = h3
        self.h4 = h4
        self.s3 = s3
        self.s4 = s4
        self.i1 = i1
        self.i2 = i2
        self.i3 = i3
        self.i4 = i4
        self.i5 = i5
    }

    public var wgQuickConfig: String {
        var lines = [
            "[Interface]",
            "PrivateKey = \(privateKey)"
        ]

        append("Address", address, to: &lines)
        append("DNS", dns, to: &lines)
        append("MTU", mtu.map(String.init), to: &lines)
        append("Jc", jc, to: &lines)
        append("Jmin", jmin, to: &lines)
        append("Jmax", jmax, to: &lines)
        append("S1", s1, to: &lines)
        append("S2", s2, to: &lines)
        append("S3", s3, to: &lines)
        append("S4", s4, to: &lines)
        append("H1", h1, to: &lines)
        append("H2", h2, to: &lines)
        append("H3", h3, to: &lines)
        append("H4", h4, to: &lines)
        append("I1", i1, to: &lines)
        append("I2", i2, to: &lines)
        append("I3", i3, to: &lines)
        append("I4", i4, to: &lines)
        append("I5", i5, to: &lines)

        lines.append("")
        lines.append("[Peer]")
        lines.append("PublicKey = \(publicKey)")
        append("PresharedKey", presharedKey, to: &lines)
        lines.append("Endpoint = \(endpoint)")
        lines.append("AllowedIPs = \(allowedIPs)")
        append("PersistentKeepalive", persistentKeepalive.map(String.init), to: &lines)

        return lines.joined(separator: "\n")
    }

    public var redactedSummary: String {
        "endpoint=\(endpoint), address=\(address ?? "none"), dns=\(dns ?? "none"), allowedIPs=\(allowedIPs)"
    }

    private func append(_ key: String, _ value: String?, to lines: inout [String]) {
        guard let value, !value.isEmpty else {
            return
        }

        lines.append("\(key) = \(value)")
    }
}

public extension AmneziaConfigDecoder {
    func decodeWireGuardConfig(from urlString: String) throws -> AmneziaWireGuardConfig {
        let payload = try decodePayload(from: urlString)
        return try AmneziaWireGuardConfigParser().parse(payload)
    }

    func decodeImportedWireGuardConfig(from value: String) throws -> AmneziaWireGuardConfig {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveContains("[Interface]"),
           trimmed.localizedCaseInsensitiveContains("[Peer]") {
            return try AmneziaWireGuardConfigParser().parse(Data(trimmed.utf8))
        }

        return try decodeWireGuardConfig(from: trimmed)
    }
}

public struct AmneziaWireGuardConfigParser: Sendable {
    public init() {}

    public func parse(_ payload: Data) throws -> AmneziaWireGuardConfig {
        if let text = String(data: payload, encoding: .utf8),
           text.localizedCaseInsensitiveContains("[Interface]"),
           text.localizedCaseInsensitiveContains("[Peer]") {
            return try parseWgQuickConfig(text)
        }

        let object = try JSONSerialization.jsonObject(with: payload)
        guard let root = object as? [String: Any] else {
            throw AmneziaWireGuardConfigError.invalidJSON
        }

        if let wgQuickConfig = recursiveWgQuickConfig(in: root) {
            return try parseWgQuickConfig(wgQuickConfig)
        }

        if isPremiumSubscriptionToken(root) {
            throw AmneziaWireGuardConfigError.premiumSubscriptionRequiresGatewayConfig
        }

        let interface = dictionary(in: root, keys: ["interface", "Interface"])
        let peer = dictionary(in: root, keys: ["peer", "Peer"]) ?? root

        guard let privateKey = firstString(in: root, interface, keys: ["privateKey", "PrivateKey"]) else {
            throw AmneziaWireGuardConfigError.missingInterfacePrivateKey
        }

        guard let publicKey = firstString(in: root, peer, keys: ["publicKey", "PublicKey"]) else {
            throw AmneziaWireGuardConfigError.missingPeerPublicKey
        }

        guard let endpoint = firstString(in: root, peer, keys: ["endpoint", "Endpoint"]) else {
            throw AmneziaWireGuardConfigError.missingEndpoint
        }

        return AmneziaWireGuardConfig(
            privateKey: privateKey,
            address: firstString(in: root, interface, keys: ["address", "Address", "clientAddress"]),
            dns: firstString(in: root, interface, keys: ["dns", "DNS"]),
            publicKey: publicKey,
            presharedKey: firstString(in: root, peer, keys: ["presharedKey", "PresharedKey"]),
            endpoint: endpoint,
            allowedIPs: firstString(in: root, peer, keys: ["allowedIPs", "AllowedIPs"]) ?? "0.0.0.0/0, ::/0",
            persistentKeepalive: firstInt(in: root, peer, keys: ["persistentKeepalive", "PersistentKeepalive"]),
            mtu: firstInt(in: root, interface, keys: ["mtu", "MTU"]),
            jc: firstString(in: root, interface, peer, keys: ["jc", "Jc"]),
            jmin: firstString(in: root, interface, peer, keys: ["jmin", "Jmin"]),
            jmax: firstString(in: root, interface, peer, keys: ["jmax", "Jmax"]),
            s1: firstString(in: root, interface, peer, keys: ["s1", "S1"]),
            s2: firstString(in: root, interface, peer, keys: ["s2", "S2"]),
            h1: firstString(in: root, interface, peer, keys: ["h1", "H1"]),
            h2: firstString(in: root, interface, peer, keys: ["h2", "H2"]),
            h3: firstString(in: root, interface, peer, keys: ["h3", "H3"]),
            h4: firstString(in: root, interface, peer, keys: ["h4", "H4"]),
            s3: firstString(in: root, interface, peer, keys: ["s3", "S3"]),
            s4: firstString(in: root, interface, peer, keys: ["s4", "S4"]),
            i1: firstString(in: root, interface, peer, keys: ["i1", "I1"]),
            i2: firstString(in: root, interface, peer, keys: ["i2", "I2"]),
            i3: firstString(in: root, interface, peer, keys: ["i3", "I3"]),
            i4: firstString(in: root, interface, peer, keys: ["i4", "I4"]),
            i5: firstString(in: root, interface, peer, keys: ["i5", "I5"])
        )
    }

    private func parseWgQuickConfig(_ text: String) throws -> AmneziaWireGuardConfig {
        let sections = parseSections(text)
        let interface = sections["interface"] ?? [:]
        let peer = sections["peer"] ?? [:]

        guard let privateKey = interface["privatekey"] else {
            throw AmneziaWireGuardConfigError.missingInterfacePrivateKey
        }

        guard let publicKey = peer["publickey"] else {
            throw AmneziaWireGuardConfigError.missingPeerPublicKey
        }

        guard let endpoint = peer["endpoint"] else {
            throw AmneziaWireGuardConfigError.missingEndpoint
        }

        return AmneziaWireGuardConfig(
            privateKey: privateKey,
            address: interface["address"],
            dns: interface["dns"],
            publicKey: publicKey,
            presharedKey: peer["presharedkey"],
            endpoint: endpoint,
            allowedIPs: peer["allowedips"] ?? "0.0.0.0/0, ::/0",
            persistentKeepalive: peer["persistentkeepalive"].flatMap(Int.init),
            mtu: interface["mtu"].flatMap(Int.init),
            jc: interface["jc"],
            jmin: interface["jmin"],
            jmax: interface["jmax"],
            s1: interface["s1"],
            s2: interface["s2"],
            h1: interface["h1"],
            h2: interface["h2"],
            h3: interface["h3"],
            h4: interface["h4"],
            s3: interface["s3"],
            s4: interface["s4"],
            i1: interface["i1"],
            i2: interface["i2"],
            i3: interface["i3"],
            i4: interface["i4"],
            i5: interface["i5"]
        )
    }

    private func parseSections(_ text: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var section: String?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let lineWithoutComment = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let line = lineWithoutComment.trimmingCharacters(in: .whitespacesAndNewlines)

            if line.isEmpty {
                continue
            }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = line
                    .dropFirst()
                    .dropLast()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if let section {
                    result[section, default: [:]] = result[section, default: [:]]
                }
                continue
            }

            guard let section, let equals = line.firstIndex(of: "=") else {
                continue
            }

            let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let previous = result[section]?[key], key == "address" || key == "dns" || key == "allowedips" {
                result[section]?[key] = "\(previous), \(value)"
            } else {
                result[section]?[key] = value
            }
        }

        return result
    }

    private func recursiveWgQuickConfig(in value: Any) -> String? {
        if let string = value as? String,
           string.localizedCaseInsensitiveContains("[Interface]"),
           string.localizedCaseInsensitiveContains("[Peer]") {
            return string
        }

        if let dictionary = value as? [String: Any] {
            for child in dictionary.values {
                if let match = recursiveWgQuickConfig(in: child) {
                    return match
                }
            }
        }

        if let array = value as? [Any] {
            for child in array {
                if let match = recursiveWgQuickConfig(in: child) {
                    return match
                }
            }
        }

        return nil
    }

    private func isPremiumSubscriptionToken(_ root: [String: Any]) -> Bool {
        guard let apiConfig = root["api_config"] as? [String: Any],
              let authData = root["auth_data"] as? [String: Any] else {
            return false
        }

        let serviceType = apiConfig["service_type"] as? String
        return serviceType == "amnezia-premium" && authData["api_key"] != nil
    }

    private func dictionary(in source: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = source[key] as? [String: Any] {
                return value
            }
        }

        return nil
    }

    private func firstString(in dictionaries: [String: Any]?..., keys: [String]) -> String? {
        for dictionary in dictionaries.compactMap({ $0 }) {
            for key in keys {
                if let value = dictionary[key] as? String, !value.isEmpty {
                    return value
                }

                if let number = dictionary[key] as? NSNumber {
                    return number.stringValue
                }
            }
        }

        return nil
    }

    private func firstInt(in dictionaries: [String: Any]?..., keys: [String]) -> Int? {
        for dictionary in dictionaries.compactMap({ $0 }) {
            for key in keys {
                if let value = dictionary[key] as? Int {
                    return value
                }

                if let string = dictionary[key] as? String, let value = Int(string) {
                    return value
                }
            }
        }

        return nil
    }
}
