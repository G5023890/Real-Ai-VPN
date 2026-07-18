import Foundation

public enum WireGuardConfigError: LocalizedError, Equatable {
    case missingInterfacePrivateKey
    case missingPeerPublicKey
    case missingEndpoint
    case unsupportedAmneziaWGField(String)

    public var errorDescription: String? {
        switch self {
        case .missingInterfacePrivateKey:
            return "The WireGuard config does not contain an interface private key."
        case .missingPeerPublicKey:
            return "The WireGuard config does not contain a peer public key."
        case .missingEndpoint:
            return "The WireGuard config does not contain a server endpoint."
        case .unsupportedAmneziaWGField(let field):
            return "The config contains the AmneziaWG-only field \(field). Import a standard WireGuard .conf profile instead."
        }
    }
}

public struct WireGuardConfig: Codable, Equatable, Sendable {
    public var privateKey: String
    public var address: String?
    public var dns: String?
    public var publicKey: String
    public var presharedKey: String?
    public var endpoint: String
    public var allowedIPs: String
    public var persistentKeepalive: Int?
    public var mtu: Int?

    public init(
        privateKey: String,
        address: String? = nil,
        dns: String? = nil,
        publicKey: String,
        presharedKey: String? = nil,
        endpoint: String,
        allowedIPs: String = "0.0.0.0/0, ::/0",
        persistentKeepalive: Int? = 25,
        mtu: Int? = nil
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
    }

    public var wgQuickConfig: String {
        var lines = ["[Interface]", "PrivateKey = \(privateKey)"]
        append("Address", address, to: &lines)
        append("DNS", dns, to: &lines)
        append("MTU", mtu.map(String.init), to: &lines)
        lines += ["", "[Peer]", "PublicKey = \(publicKey)"]
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
        guard let value, !value.isEmpty else { return }
        lines.append("\(key) = \(value)")
    }
}

public struct WireGuardConfigDecoder: Sendable {
    public init() {}

    public func decodeImportedWireGuardConfig(from value: String) throws -> WireGuardConfig {
        let sections = parseSections(value)
        let interface = sections["interface"] ?? [:]
        let peer = sections["peer"] ?? [:]

        for field in ["jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5"] {
            if interface[field] != nil || peer[field] != nil {
                throw WireGuardConfigError.unsupportedAmneziaWGField(field)
            }
        }

        guard let privateKey = interface["privatekey"] else {
            throw WireGuardConfigError.missingInterfacePrivateKey
        }
        guard let publicKey = peer["publickey"] else {
            throw WireGuardConfigError.missingPeerPublicKey
        }
        guard let endpoint = peer["endpoint"] else {
            throw WireGuardConfigError.missingEndpoint
        }

        return WireGuardConfig(
            privateKey: privateKey,
            address: interface["address"],
            dns: interface["dns"],
            publicKey: publicKey,
            presharedKey: peer["presharedkey"],
            endpoint: endpoint,
            allowedIPs: peer["allowedips"] ?? "0.0.0.0/0, ::/0",
            persistentKeepalive: peer["persistentkeepalive"].flatMap(Int.init),
            mtu: interface["mtu"].flatMap(Int.init)
        )
    }

    private func parseSections(_ text: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var section: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let withoutComment = rawLine.split(maxSplits: 1, whereSeparator: { $0 == "#" || $0 == ";" }).first ?? ""
            let line = withoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = line.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                continue
            }
            guard let section, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let previous = result[section]?[key], ["address", "dns", "allowedips"].contains(key) {
                result[section]?[key] = "\(previous), \(value)"
            } else {
                result[section, default: [:]][key] = value
            }
        }
        return result
    }
}
