import Foundation
import NetworkExtension

public enum VPNConnectionStatus: String, Hashable, Codable, Sendable {
    case invalid
    case disconnected
    case connecting
    case connected
    case reasserting
    case disconnecting
    case unknown

    public var isConnectedOrConnecting: Bool {
        switch self {
        case .connecting, .connected, .reasserting:
            return true
        case .invalid, .disconnected, .disconnecting, .unknown:
            return false
        }
    }
}

public struct VPNProfileConfiguration: Hashable, Codable, Sendable {
    public var localizedDescription: String
    public var providerBundleIdentifier: String
    public var serverID: String
    public var regionCode: String

    public init(
        localizedDescription: String = "Real Ai VPN",
        providerBundleIdentifier: String = "com.codex.RealAiVPN.PacketTunnel",
        serverID: String,
        regionCode: String
    ) {
        self.localizedDescription = localizedDescription
        self.providerBundleIdentifier = providerBundleIdentifier
        self.serverID = serverID
        self.regionCode = regionCode
    }
}

public enum RealVPNProfileError: LocalizedError, Equatable {
    case missingManager
    case missingSession
    case preferencesSaveFailed(String)
    case preferencesLoadFailed(String)
    case startFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingManager:
            return "VPN profile manager is not loaded."
        case .missingSession:
            return "VPN tunnel session is not available."
        case .preferencesSaveFailed(let message):
            return "Could not save VPN preferences: \(message)"
        case .preferencesLoadFailed(let message):
            return "Could not load VPN preferences: \(message)"
        case .startFailed(let message):
            return "Could not start VPN tunnel: \(message)"
        }
    }
}

@MainActor
public final class RealVPNProfileManager: ObservableObject {
    @Published public private(set) var status: VPNConnectionStatus = .unknown
    @Published public private(set) var lastErrorMessage: String?

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    public init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatus()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public func prepareProfile(configuration: VPNProfileConfiguration) async {
        do {
            manager = try await loadOrCreateManager(configuration: configuration)
            refreshStatus()
        } catch {
            lastErrorMessage = error.localizedDescription
            status = .unknown
        }
    }

    public func connect(configuration: VPNProfileConfiguration, transientAmneziaKey: String? = nil) async {
        do {
            let manager = try await loadOrCreateManager(configuration: configuration)
            self.manager = manager
            try await save(manager)
            var options: [String: NSObject] = [:]
            if let transientAmneziaKey {
                options["amneziaVPNURL"] = transientAmneziaKey as NSString
            }
            try manager.connection.startVPNTunnel(options: options)
            refreshStatus()
            lastErrorMessage = nil
        } catch let error as RealVPNProfileError {
            lastErrorMessage = error.localizedDescription
            status = .disconnected
        } catch {
            lastErrorMessage = RealVPNProfileError.startFailed(error.localizedDescription).localizedDescription
            status = .disconnected
        }
    }

    public func disconnect() {
        manager?.connection.stopVPNTunnel()
        refreshStatus()
    }

    public func refreshStatus() {
        guard let manager else {
            status = .unknown
            return
        }

        status = VPNConnectionStatus(manager.connection.status)
    }

    private func loadOrCreateManager(configuration: VPNProfileConfiguration) async throws -> NETunnelProviderManager {
        let managers: [NETunnelProviderManager]

        do {
            managers = try await NETunnelProviderManager.loadAllFromPreferences()
        } catch {
            throw RealVPNProfileError.preferencesLoadFailed(error.localizedDescription)
        }

        let manager = managers.first { $0.localizedDescription == configuration.localizedDescription } ?? NETunnelProviderManager()
        let protocolConfiguration = NETunnelProviderProtocol()
        protocolConfiguration.providerBundleIdentifier = configuration.providerBundleIdentifier
        protocolConfiguration.serverAddress = configuration.serverID
        protocolConfiguration.providerConfiguration = [
            "serverID": configuration.serverID,
            "regionCode": configuration.regionCode,
            "mode": "prototype"
        ]

        manager.localizedDescription = configuration.localizedDescription
        manager.protocolConfiguration = protocolConfiguration
        manager.isEnabled = true

        return manager
    }

    private func save(_ manager: NETunnelProviderManager) async throws {
        do {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        } catch {
            throw RealVPNProfileError.preferencesSaveFailed(error.localizedDescription)
        }
    }
}

private extension VPNConnectionStatus {
    init(_ status: NEVPNStatus) {
        switch status {
        case .invalid:
            self = .invalid
        case .disconnected:
            self = .disconnected
        case .connecting:
            self = .connecting
        case .connected:
            self = .connected
        case .reasserting:
            self = .reasserting
        case .disconnecting:
            self = .disconnecting
        @unknown default:
            self = .unknown
        }
    }
}
