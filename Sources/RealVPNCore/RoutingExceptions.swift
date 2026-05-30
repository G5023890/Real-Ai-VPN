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
