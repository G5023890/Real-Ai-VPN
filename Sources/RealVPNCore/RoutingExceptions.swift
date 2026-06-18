import Foundation

public enum RoutingExceptionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case forceVPN
    case bypassVPN

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .forceVPN:
            return "Через VPN"
        case .bypassVPN:
            return "Без VPN"
        }
    }
}

public struct RoutingExceptionRule: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var value: String
    public var mode: RoutingExceptionMode
    public var isEnabled: Bool
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        value: String,
        mode: RoutingExceptionMode,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.value = value
        self.mode = mode
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

public struct RoutingExceptionCollection: Codable, Equatable, Sendable {
    public var rules: [RoutingExceptionRule]

    public init(rules: [RoutingExceptionRule] = []) {
        self.rules = rules
    }

    public var enabledRules: [RoutingExceptionRule] {
        rules.filter(\.isEnabled)
    }
}

public enum RoutingExceptionProtectedProbeGuard {
    public static let protectedHosts: Set<String> = [
        "ya.ru",
        "www.mos.ru",
        "www.rbc.ru",
        "www.gosuslugi.ru",
        "www.cloudflare.com",
        "1.1.1.1",
        "example.com",
        "www.iana.org",
        "www.wikipedia.org",
        "www.bing.com",
        "duckduckgo.com",
        "www.mozilla.org",
        "www.debian.org",
        "www.kernel.org",
        "9.9.9.9",
        "208.67.222.222",
        "cloudflare-dns.com",
        "dns.quad9.net",
        "77.88.8.8"
    ]

    public static func protectedMatch(for value: String) -> String? {
        let normalized = normalizedRoutingValue(value)
        guard !normalized.isEmpty else {
            return nil
        }

        for protectedHost in protectedHosts {
            if normalized == protectedHost {
                return protectedHost
            }

            if isDomain(normalized),
               isDomain(protectedHost),
               protectedHost.hasSuffix(".\(normalized)") {
                return protectedHost
            }

            if let cidr = IPv4CIDR(normalized),
               let protectedIP = IPv4Address(protectedHost),
               cidr.contains(protectedIP) {
                return protectedHost
            }
        }

        return nil
    }

    public static func isProtected(_ value: String) -> Bool {
        protectedMatch(for: value) != nil
    }

    private static func normalizedRoutingValue(_ value: String) -> String {
        var normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let url = URL(string: normalized), let host = url.host {
            normalized = host
        } else {
            normalized = normalized
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .split(separator: "/")
                .first
                .map(String.init) ?? normalized
        }

        if normalized.hasPrefix("*.") {
            normalized = String(normalized.dropFirst(2))
        }

        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func isDomain(_ value: String) -> Bool {
        IPv4Address(value) == nil && IPv4CIDR(value) == nil && value.contains(".")
    }
}

public struct RoutingExceptionStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "routingExceptions.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> RoutingExceptionCollection {
        guard let data = defaults.data(forKey: key),
              let collection = try? JSONDecoder().decode(RoutingExceptionCollection.self, from: data) else {
            return RoutingExceptionCollection()
        }

        return collection
    }

    public func save(_ collection: RoutingExceptionCollection) {
        guard let data = try? JSONEncoder().encode(collection) else {
            return
        }

        defaults.set(data, forKey: key)
    }
}

private struct IPv4Address: Equatable, Sendable {
    let rawValue: UInt32

    init?(_ value: String) {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else {
            return nil
        }

        var result: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else {
                return nil
            }
            result = (result << 8) | UInt32(octet)
        }

        rawValue = result
    }
}

private struct IPv4CIDR: Sendable {
    let network: UInt32
    let mask: UInt32

    init?(_ value: String) {
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        guard let address = IPv4Address(parts[0]) else {
            return nil
        }

        let prefix: UInt8
        if parts.count == 2 {
            guard let parsedPrefix = UInt8(parts[1]), parsedPrefix <= 32 else {
                return nil
            }
            prefix = parsedPrefix
        } else {
            prefix = 32
        }

        mask = prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)
        network = address.rawValue & mask
    }

    func contains(_ address: IPv4Address) -> Bool {
        (address.rawValue & mask) == network
    }
}

public enum RoutingExceptionCodec {
    public static func encode(_ collection: RoutingExceptionCollection) -> String? {
        guard let data = try? JSONEncoder().encode(collection) else {
            return nil
        }

        return data.base64EncodedString()
    }

    public static func decode(_ encoded: String?) -> RoutingExceptionCollection {
        guard let encoded,
              let data = Data(base64Encoded: encoded),
              let collection = try? JSONDecoder().decode(RoutingExceptionCollection.self, from: data) else {
            return RoutingExceptionCollection()
        }

        return collection
    }
}
