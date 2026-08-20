import Foundation
import NetworkExtension
import os

private let vpnProfileLogger = Logger(
    subsystem: "com.codex.RealAiVPN",
    category: "VPNProfileManager"
)

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
    public var protocolKind: String
    public var killSwitchEnabled: Bool
    public var dnsProtectionEnabled: Bool
    public var localNetworkAccessEnabled: Bool
    public var ipv6LeakProtectionEnabled: Bool
    public var ipv4OnlyCompatibilityEnabled: Bool
    public var autoReconnectOnDemandEnabled: Bool
    public var preserveExistingOnDemandReconnect: Bool

    public init(
        localizedDescription: String = "Real Ai Router",
        providerBundleIdentifier: String = "com.codex.RealAiVPN.PacketTunnel",
        serverID: String,
        regionCode: String,
        protocolKind: String = "unknown",
        killSwitchEnabled: Bool = false,
        dnsProtectionEnabled: Bool = true,
        localNetworkAccessEnabled: Bool = true,
        ipv6LeakProtectionEnabled: Bool = true,
        ipv4OnlyCompatibilityEnabled: Bool = false,
        autoReconnectOnDemandEnabled: Bool = false,
        preserveExistingOnDemandReconnect: Bool = false
    ) {
        self.localizedDescription = localizedDescription
        self.providerBundleIdentifier = providerBundleIdentifier
        self.serverID = serverID
        self.regionCode = regionCode
        self.protocolKind = protocolKind
        self.killSwitchEnabled = killSwitchEnabled
        self.dnsProtectionEnabled = dnsProtectionEnabled
        self.localNetworkAccessEnabled = localNetworkAccessEnabled
        self.ipv6LeakProtectionEnabled = ipv6LeakProtectionEnabled
        self.ipv4OnlyCompatibilityEnabled = ipv4OnlyCompatibilityEnabled
        self.autoReconnectOnDemandEnabled = autoReconnectOnDemandEnabled
        self.preserveExistingOnDemandReconnect = preserveExistingOnDemandReconnect
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
    @Published public private(set) var lastProviderBundleIdentifier: String?
    @Published public private(set) var transitionDetail: String?

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var operationGeneration = 0

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
            vpnProfileLogger.info("Preparing VPN profile provider=\(configuration.providerBundleIdentifier, privacy: .public) serverID=\(configuration.serverID, privacy: .public)")
            NSLog("RealAiVPN VPNProfileManager prepare provider=%@ serverID=%@",
                  configuration.providerBundleIdentifier,
                  configuration.serverID)
            manager = try await loadOrCreateManager(configuration: configuration)
            if let manager {
                try await save(manager)
            }
            lastProviderBundleIdentifier = configuration.providerBundleIdentifier
            refreshStatus()
        } catch {
            vpnProfileLogger.error("Could not prepare VPN profile: \(error.localizedDescription, privacy: .public)")
            NSLog("RealAiVPN VPNProfileManager prepare failed: %@", error.localizedDescription)
            lastErrorMessage = error.localizedDescription
            status = .unknown
        }
    }

    public func connect(
        configuration: VPNProfileConfiguration,
        transientWireGuardConfig: String? = nil,
        routingExceptions: RoutingExceptionCollection = RoutingExceptionCollection()
    ) async {
        let operation = beginOperation()
        do {
            reportTransition("Preparing VPN switch")
            vpnProfileLogger.info("Starting VPN provider=\(configuration.providerBundleIdentifier, privacy: .public) serverID=\(configuration.serverID, privacy: .public) hasConfig=\((transientWireGuardConfig?.isEmpty == false), privacy: .public)")
            NSLog("RealAiVPN VPNProfileManager connect provider=%@ serverID=%@ hasConfig=%@",
                  configuration.providerBundleIdentifier,
                  configuration.serverID,
                  (transientWireGuardConfig?.isEmpty == false) ? "true" : "false")
            lastErrorMessage = nil
            lastProviderBundleIdentifier = configuration.providerBundleIdentifier
            try await stopAllRealAiManagers()
            guard isCurrent(operation) else { return }

            reportTransition("Loading selected VPN profile")
            var manager = try await loadOrCreateManager(configuration: configuration)
            guard isCurrent(operation) else { return }
            self.manager = manager
            reportTransition("Saving selected VPN profile")
            manager = try await saveAndReload(manager, configuration: configuration)
            guard isCurrent(operation) else { return }
            self.manager = manager
            var options: [String: NSObject] = [:]
            if let transientWireGuardConfig {
                options["wireGuardConfig"] = transientWireGuardConfig as NSString
            }
            if let encodedExceptions = RoutingExceptionCodec.encode(routingExceptions) {
                options["routingExceptions"] = encodedExceptions as NSString
            }
            options["killSwitchEnabled"] = NSNumber(value: configuration.killSwitchEnabled)
            options["dnsProtectionEnabled"] = NSNumber(value: configuration.dnsProtectionEnabled)
            options["localNetworkAccessEnabled"] = NSNumber(value: configuration.localNetworkAccessEnabled)
            options["ipv6LeakProtectionEnabled"] = NSNumber(value: configuration.ipv6LeakProtectionEnabled)
            options["ipv4OnlyCompatibilityEnabled"] = NSNumber(value: configuration.ipv4OnlyCompatibilityEnabled)
            reportTransition("Starting \(configuration.protocolKind) tunnel")
            try manager.connection.startVPNTunnel(options: options)
            await waitForSettledStatus(manager, operation: operation)
            guard isCurrent(operation) else { return }
            vpnProfileLogger.info("startVPNTunnel returned status=\(self.status.rawValue, privacy: .public)")
            NSLog("RealAiVPN VPNProfileManager startVPNTunnel returned status=%@",
                  self.status.rawValue)
            if status == .disconnected || status == .invalid {
                lastErrorMessage = "NetworkExtension returned \(status.rawValue) after start for \(configuration.providerBundleIdentifier)."
                reportTransition("Tunnel start ended as \(status.rawValue)")
            } else {
                reportTransition("Tunnel status: \(status.rawValue)")
            }
        } catch let error as RealVPNProfileError {
            vpnProfileLogger.error("VPN start failed: \(error.localizedDescription, privacy: .public)")
            NSLog("RealAiVPN VPNProfileManager start failed: %@", error.localizedDescription)
            lastErrorMessage = error.localizedDescription
            status = .disconnected
            reportTransition("VPN switch failed: \(error.localizedDescription)")
        } catch {
            vpnProfileLogger.error("VPN start failed: \(error.localizedDescription, privacy: .public)")
            NSLog("RealAiVPN VPNProfileManager start failed: %@", error.localizedDescription)
            lastErrorMessage = RealVPNProfileError.startFailed(error.localizedDescription).localizedDescription
            status = .disconnected
            reportTransition("VPN switch failed: \(error.localizedDescription)")
        }
    }

    private func stopAllRealAiManagers() async throws {
        let managers: [NETunnelProviderManager]
        do {
            managers = try await NETunnelProviderManager.loadAllFromPreferences()
        } catch {
            throw RealVPNProfileError.preferencesLoadFailed(error.localizedDescription)
        }

        for manager in managers where manager.isRealAiRouterManager {
            let status = VPNConnectionStatus(manager.connection.status)
            reportTransition("Stopping \((manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier ?? "unknown")")
            NSLog("RealAiVPN VPNProfileManager stopping conflicting provider=%@ status=%@ description=%@",
                  (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier ?? "unknown",
                  status.rawValue,
                  manager.localizedDescription ?? "unknown")

            if manager.isOnDemandEnabled {
                manager.isOnDemandEnabled = false
                manager.onDemandRules = nil
                try await save(manager)
            }

            switch status {
            case .connecting, .connected, .reasserting, .disconnecting:
                manager.connection.stopVPNTunnel()
                guard await waitForManagerToDisconnect(manager) else {
                    throw RealVPNProfileError.startFailed("Timed out waiting for the previous VPN profile to disconnect.")
                }
            case .invalid, .disconnected, .unknown:
                break
            }
        }
    }

    public func disconnect() {
        _ = beginOperation()
        reportTransition("Disconnecting VPN")
        vpnProfileLogger.info("Stopping VPN tunnel")
        NSLog("RealAiVPN VPNProfileManager disconnect")
        manager?.connection.stopVPNTunnel()
        refreshStatus()
    }

    public func disconnectDisablingOnDemand() async {
        _ = beginOperation()
        reportTransition("Disconnecting VPN")
        vpnProfileLogger.info("Stopping VPN tunnel after disabling On Demand")
        NSLog("RealAiVPN VPNProfileManager disconnectDisablingOnDemand")
        if let manager {
            do {
                manager.isOnDemandEnabled = false
                manager.onDemandRules = nil
                try await save(manager)
            } catch {
                vpnProfileLogger.error("Could not disable On Demand before disconnect: \(error.localizedDescription, privacy: .public)")
                NSLog("RealAiVPN VPNProfileManager disable On Demand failed: %@", error.localizedDescription)
                lastErrorMessage = error.localizedDescription
            }
        }
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

        let manager = managers.first {
            guard $0.localizedDescription == configuration.localizedDescription,
                  let protocolConfiguration = $0.protocolConfiguration as? NETunnelProviderProtocol else {
                return false
            }
            return protocolConfiguration.providerBundleIdentifier == configuration.providerBundleIdentifier
        } ?? managers.first {
            guard ["Real Ai Router", "Real Ai VPN"].contains($0.localizedDescription),
                  let protocolConfiguration = $0.protocolConfiguration as? NETunnelProviderProtocol else {
                return false
            }
            return protocolConfiguration.providerBundleIdentifier == configuration.providerBundleIdentifier
        } ?? NETunnelProviderManager()
        let shouldEnableOnDemand = configuration.autoReconnectOnDemandEnabled
            || (configuration.preserveExistingOnDemandReconnect && manager.isOnDemandEnabled)
        NSLog("RealAiVPN VPNProfileManager loadOrCreate matchedExisting=%@ provider=%@",
              managers.contains(where: {
                  guard $0.localizedDescription == configuration.localizedDescription,
                        let protocolConfiguration = $0.protocolConfiguration as? NETunnelProviderProtocol else {
                      return false
                  }
                  return protocolConfiguration.providerBundleIdentifier == configuration.providerBundleIdentifier
              }) ? "true" : "false",
              configuration.providerBundleIdentifier)
        let protocolConfiguration = NETunnelProviderProtocol()
        protocolConfiguration.providerBundleIdentifier = configuration.providerBundleIdentifier
        protocolConfiguration.serverAddress = configuration.serverID
        protocolConfiguration.providerConfiguration = [
            "serverID": configuration.serverID,
            "regionCode": configuration.regionCode,
            "protocolKind": configuration.protocolKind,
            "mode": "prototype",
            "killSwitchEnabled": NSNumber(value: configuration.killSwitchEnabled),
            "dnsProtectionEnabled": NSNumber(value: configuration.dnsProtectionEnabled),
            "localNetworkAccessEnabled": NSNumber(value: configuration.localNetworkAccessEnabled),
            "ipv6LeakProtectionEnabled": NSNumber(value: configuration.ipv6LeakProtectionEnabled),
            "ipv4OnlyCompatibilityEnabled": NSNumber(value: configuration.ipv4OnlyCompatibilityEnabled)
        ]
        #if os(iOS)
        protocolConfiguration.excludeLocalNetworks = configuration.localNetworkAccessEnabled
        if #available(iOS 17.4, *) {
            protocolConfiguration.excludeDeviceCommunication = configuration.localNetworkAccessEnabled
        }
        #endif

        manager.localizedDescription = configuration.localizedDescription
        manager.protocolConfiguration = protocolConfiguration
        manager.isEnabled = true
        manager.isOnDemandEnabled = shouldEnableOnDemand
        if shouldEnableOnDemand {
            let connectRule = NEOnDemandRuleConnect()
            connectRule.interfaceTypeMatch = .any
            manager.onDemandRules = [connectRule]
        } else {
            manager.onDemandRules = nil
        }
        NSLog("RealAiVPN VPNProfileManager onDemand=%@ provider=%@",
              shouldEnableOnDemand ? "true" : "false",
              configuration.providerBundleIdentifier)

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

    private func waitForSettledStatus(
        _ expectedManager: NETunnelProviderManager,
        operation: Int,
        timeoutSeconds: Double = 15
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        repeat {
            guard isCurrent(operation) else { return }
            status = VPNConnectionStatus(expectedManager.connection.status)
            if status == .connected || status == .reasserting || status == .disconnected || status == .invalid {
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        } while Date() < deadline

        guard isCurrent(operation) else { return }
        status = VPNConnectionStatus(expectedManager.connection.status)
    }

    private func waitForManagerToDisconnect(
        _ manager: NETunnelProviderManager,
        timeoutSeconds: Double = 15
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        repeat {
            let status = VPNConnectionStatus(manager.connection.status)
            if status == .disconnected || status == .invalid {
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        } while Date() < deadline
        return false
    }

    private func saveAndReload(
        _ manager: NETunnelProviderManager,
        configuration: VPNProfileConfiguration
    ) async throws -> NETunnelProviderManager {
        try await save(manager)
        let managers: [NETunnelProviderManager]
        do {
            managers = try await NETunnelProviderManager.loadAllFromPreferences()
        } catch {
            throw RealVPNProfileError.preferencesLoadFailed(error.localizedDescription)
        }

        guard let reloadedManager = managers.first(where: {
            guard $0.localizedDescription == configuration.localizedDescription,
                  let tunnelProtocol = $0.protocolConfiguration as? NETunnelProviderProtocol else {
                return false
            }
            return tunnelProtocol.providerBundleIdentifier == configuration.providerBundleIdentifier
        }) else {
            throw RealVPNProfileError.missingManager
        }

        try await reloadedManager.loadFromPreferences()
        return reloadedManager
    }

    private func beginOperation() -> Int {
        operationGeneration += 1
        return operationGeneration
    }

    private func isCurrent(_ operation: Int) -> Bool {
        operation == operationGeneration
    }

    private func reportTransition(_ detail: String) {
        transitionDetail = detail
        vpnProfileLogger.info("VPN transition: \(detail, privacy: .public)")
        NSLog("RealAiVPN VPNProfileManager transition=%@", detail)
    }
}

private extension NETunnelProviderManager {
    var isRealAiRouterManager: Bool {
        guard protocolConfiguration is NETunnelProviderProtocol,
              let description = localizedDescription else {
            return false
        }

        return description == "Real Ai Router"
            || description == "Real Ai VPN"
            || description.hasPrefix("Real Ai Router ")
            || description.hasPrefix("Real Ai VPN ")
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
