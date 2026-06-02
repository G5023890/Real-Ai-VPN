import Foundation
import NetworkExtension
import os
import RealVPNCore

#if SINGBOX_TUNNEL && canImport(Libbox)
import Libbox
import Network
import UserNotifications
#if os(macOS)
import CoreWLAN
#endif

private let singBoxLogger = Logger(
    subsystem: "com.codex.RealAiVPN.PacketTunnel",
    category: "SingBoxTunnelRuntime"
)

final class SingBoxTunnelRuntime {
    private weak var provider: NEPacketTunnelProvider?
    private var commandServer: LibboxCommandServer?
    private var platformInterface: SingBoxPlatformInterface?
    private let diagnosticsStore = TunnelDiagnosticsStore()

    init(provider: NEPacketTunnelProvider) {
        self.provider = provider
        LibboxPrepareCrashSignalHandlers()
        LibboxReinstallCrashSignalHandlers()
    }

    func start(configJSON: String) async throws {
        saveDiagnostic(stage: "singbox-start", message: "Starting sing-box runtime.")
        NSLog("RealAiVPN SingBoxTunnelRuntime start entered configBytes=%ld", configJSON.utf8.count)
        guard let provider else {
            saveDiagnostic(stage: "singbox-provider-released", message: "Packet Tunnel provider was released before sing-box could start.")
            NSLog("RealAiVPN SingBoxTunnelRuntime provider released")
            throw SingBoxTunnelRuntimeError.providerReleased
        }

        let directories = try Self.runtimeDirectories()
        let setupOptions = LibboxSetupOptions()
        setupOptions.basePath = directories.base.path
        setupOptions.workingPath = directories.working.path
        setupOptions.tempPath = directories.temp.path
        setupOptions.logMaxLines = 3000
        setupOptions.debug = false
        setupOptions.crashReportSource = "RealAiVPNPacketTunnel"
        #if os(macOS)
        setupOptions.oomKillerEnabled = false
        setupOptions.oomKillerDisabled = true
        #else
        setupOptions.commandServerListenPort = 19876
        setupOptions.commandServerSecret = UUID().uuidString
        setupOptions.oomKillerEnabled = false
        setupOptions.oomKillerDisabled = true
        #endif

        var setupError: NSError?
        LibboxSetup(setupOptions, &setupError)
        if let setupError {
            singBoxLogger.error("sing-box setup failed: \(setupError.localizedDescription, privacy: .public)")
            saveDiagnostic(stage: "singbox-setup-failed", message: setupError.localizedDescription)
            NSLog("RealAiVPN SingBoxTunnelRuntime setup failed: %@", setupError.localizedDescription)
            throw SingBoxTunnelRuntimeError.setupFailed(setupError.localizedDescription)
        }
        LibboxPromoteOOMDraft()
        saveDiagnostic(stage: "singbox-setup-ok", message: "Libbox setup completed.")
        NSLog("RealAiVPN SingBoxTunnelRuntime setup ok")

        let platformInterface = SingBoxPlatformInterface(provider: provider)
        var commandServerError: NSError?
        guard let commandServer = LibboxNewCommandServer(platformInterface, platformInterface, &commandServerError) else {
            singBoxLogger.error("sing-box command server could not be created: \(commandServerError?.localizedDescription ?? "unknown", privacy: .public)")
            saveDiagnostic(stage: "singbox-command-server-failed", message: commandServerError?.localizedDescription ?? "unknown")
            NSLog("RealAiVPN SingBoxTunnelRuntime command server failed: %@",
                  commandServerError?.localizedDescription ?? "unknown")
            throw SingBoxTunnelRuntimeError.commandServerFailed(commandServerError?.localizedDescription ?? "unknown")
        }
        saveDiagnostic(stage: "singbox-command-server-ok", message: "Command server created.")
        NSLog("RealAiVPN SingBoxTunnelRuntime command server ok")

        do {
            try commandServer.start()
            try commandServer.startOrReloadService(configJSON, options: LibboxOverrideOptions())
        } catch {
            commandServer.close()
            singBoxLogger.error("sing-box service failed to start: \(error.localizedDescription, privacy: .public)")
            saveDiagnostic(stage: "singbox-service-failed", message: error.localizedDescription)
            NSLog("RealAiVPN SingBoxTunnelRuntime service failed: %@", error.localizedDescription)
            throw SingBoxTunnelRuntimeError.startFailed(error.localizedDescription)
        }

        self.platformInterface = platformInterface
        self.commandServer = commandServer
        singBoxLogger.info("sing-box runtime started")
        saveDiagnostic(stage: "singbox-started", message: "sing-box runtime started.")
        NSLog("RealAiVPN SingBoxTunnelRuntime started")
    }

    func stop() async {
        do {
            try commandServer?.closeService()
        } catch {
            singBoxLogger.error("Could not close sing-box service: \(error.localizedDescription, privacy: .public)")
        }
        commandServer?.close()
        commandServer = nil
        platformInterface?.reset()
        platformInterface = nil
    }

    private static func runtimeDirectories() throws -> (base: URL, working: URL, temp: URL) {
        #if os(iOS) || os(tvOS)
        let root = URL(fileURLWithPath: "/tmp/raivpn-sb", isDirectory: true)
        let working = root.appendingPathComponent("w", isDirectory: true)
        let temp = root.appendingPathComponent("t", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            return (root, working, temp)
        } catch {
            let fallbackRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("sb", isDirectory: true)
            let fallbackWorking = fallbackRoot.appendingPathComponent("w", isDirectory: true)
            let fallbackTemp = fallbackRoot.appendingPathComponent("t", isDirectory: true)
            try FileManager.default.createDirectory(at: fallbackWorking, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: fallbackTemp, withIntermediateDirectories: true)
            return (fallbackRoot, fallbackWorking, fallbackTemp)
        }
        #else
        let root = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("RealAiVPN/SingBox", isDirectory: true)
        guard let root else {
            throw SingBoxTunnelRuntimeError.runtimeDirectoryUnavailable
        }

        let working = root.appendingPathComponent("Working", isDirectory: true)
        let temp = root.appendingPathComponent("Temp", isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return (root, working, temp)
        #endif
    }

    private func saveDiagnostic(stage: String, message: String) {
        diagnosticsStore.save(TunnelDiagnosticSnapshot(
            providerBundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            stage: stage,
            message: message
        ))
    }
}

private enum SingBoxTunnelRuntimeError: LocalizedError, CustomNSError {
    case providerReleased
    case runtimeDirectoryUnavailable
    case setupFailed(String)
    case commandServerFailed(String)
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .providerReleased:
            return "Packet Tunnel provider was released before sing-box could start."
        case .runtimeDirectoryUnavailable:
            return "Could not create sing-box runtime directories."
        case .setupFailed(let message):
            return "sing-box setup failed: \(message)"
        case .commandServerFailed(let message):
            return "sing-box command server could not be created: \(message)"
        case .startFailed(let message):
            return "sing-box service failed to start: \(message)"
        }
    }

    static var errorDomain: String {
        "com.codex.RealAiVPN.SingBoxTunnelRuntime"
    }

    var errorCode: Int {
        switch self {
        case .providerReleased:
            return 1
        case .runtimeDirectoryUnavailable:
            return 2
        case .setupFailed:
            return 3
        case .commandServerFailed:
            return 4
        case .startFailed:
            return 5
        }
    }

    var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: errorDescription ?? "sing-box runtime failed"]
    }
}

private final class SingBoxPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private weak var provider: NEPacketTunnelProvider?
    private var networkSettings: NEPacketTunnelNetworkSettings?
    private var nwMonitor: NWPathMonitor?
    private let diagnosticsStore = TunnelDiagnosticsStore()

    init(provider: NEPacketTunnelProvider) {
        self.provider = provider
    }

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        try runBlocking {
            try await self.openTunAsync(options, ret0_)
        }
    }

    private func openTunAsync(_ options: LibboxTunOptionsProtocol?, _ ret0_: UnsafeMutablePointer<Int32>?) async throws {
        guard let provider else {
            throw NSError(domain: "SingBoxPlatformInterface", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing tunnel provider"])
        }
        guard let options, let ret0_ else {
            throw NSError(domain: "SingBoxPlatformInterface", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing TUN options"])
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: options.getMTU())

        var dnsSettings: NEDNSSettings?
        if options.getDNSMode()!.value != LibboxDNSModeDisabled {
            let iterator = try options.getDNSServerAddress()
            var servers: [String] = []
            while iterator.hasNext() {
                servers.append(iterator.next())
            }
            if !servers.isEmpty {
                let newDNSSettings = NEDNSSettings(servers: servers)
                settings.dnsSettings = newDNSSettings
                dnsSettings = newDNSSettings
            }
        }

        let ipv4AddressIterator = options.getInet4Address()!
        var ipv4Addresses: [String] = []
        var ipv4Masks: [String] = []
        while ipv4AddressIterator.hasNext() {
            let prefix = ipv4AddressIterator.next()!
            ipv4Addresses.append(prefix.address())
            ipv4Masks.append(prefix.mask())
        }
        if !ipv4Addresses.isEmpty {
            let ipv4 = NEIPv4Settings(addresses: ipv4Addresses, subnetMasks: ipv4Masks)
            ipv4.includedRoutes = try ipv4Routes(from: options.getInet4RouteAddress(), defaultRoute: true)
            ipv4.excludedRoutes = try ipv4Routes(from: options.getInet4RouteExcludeAddress(), defaultRoute: false)
            settings.ipv4Settings = ipv4
            if ipv4.includedRoutes?.contains(where: { $0.destinationAddress == "0.0.0.0" && $0.destinationSubnetMask == "0.0.0.0" }) != true {
                dnsSettings?.matchDomains = [""]
                dnsSettings?.matchDomainsNoSearch = true
            }
        }

        let ipv6AddressIterator = options.getInet6Address()!
        var ipv6Addresses: [String] = []
        var ipv6Prefixes: [NSNumber] = []
        while ipv6AddressIterator.hasNext() {
            let prefix = ipv6AddressIterator.next()!
            ipv6Addresses.append(prefix.address())
            ipv6Prefixes.append(NSNumber(value: prefix.prefix()))
        }
        if !ipv6Addresses.isEmpty {
            let ipv6 = NEIPv6Settings(addresses: ipv6Addresses, networkPrefixLengths: ipv6Prefixes)
            ipv6.includedRoutes = try ipv6Routes(from: options.getInet6RouteAddress(), defaultRoute: true)
            ipv6.excludedRoutes = try ipv6Routes(from: options.getInet6RouteExcludeAddress(), defaultRoute: false)
            settings.ipv6Settings = ipv6
        }

        networkSettings = settings
        saveDiagnostic(stage: "singbox-open-tun-settings", message: "Applying packet tunnel network settings.")
        try await provider.setTunnelNetworkSettings(settings)
        saveDiagnostic(stage: "singbox-open-tun-settings-ok", message: "Packet tunnel network settings applied.")

        if let fd = provider.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = fd
            saveDiagnostic(stage: "singbox-open-tun-fd-ok", message: "Packet flow file descriptor acquired.")
            return
        }

        let fallbackFD = LibboxGetTunnelFileDescriptor()
        guard fallbackFD != -1 else {
            saveDiagnostic(stage: "singbox-open-tun-fd-failed", message: "Could not acquire TUN file descriptor.")
            throw NSError(domain: "SingBoxPlatformInterface", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing TUN file descriptor"])
        }
        ret0_.pointee = fallbackFD
        saveDiagnostic(stage: "singbox-open-tun-fallback-fd-ok", message: "Fallback TUN file descriptor acquired.")
    }

    private func saveDiagnostic(stage: String, message: String) {
        diagnosticsStore.save(TunnelDiagnosticSnapshot(
            providerBundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            stage: stage,
            message: message
        ))
    }

    private func ipv4Routes(from iterator: LibboxRoutePrefixIteratorProtocol?, defaultRoute: Bool) throws -> [NEIPv4Route] {
        var routes: [NEIPv4Route] = []
        guard let iterator else {
            return defaultRoute ? [.default()] : []
        }
        while iterator.hasNext() {
            let prefix = iterator.next()!
            routes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
        }
        if routes.isEmpty, defaultRoute {
            routes.append(.default())
        }
        return routes
    }

    private func ipv6Routes(from iterator: LibboxRoutePrefixIteratorProtocol?, defaultRoute: Bool) throws -> [NEIPv6Route] {
        var routes: [NEIPv6Route] = []
        guard let iterator else {
            return defaultRoute ? [.default()] : []
        }
        while iterator.hasNext() {
            let prefix = iterator.next()!
            routes.append(NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix())))
        }
        if routes.isEmpty, defaultRoute {
            routes.append(.default())
        }
        return routes
    }

    func usePlatformAutoDetectControl() -> Bool { false }
    func autoDetectControl(_: Int32) throws {}
    func useProcFS() -> Bool { false }
    func underNetworkExtension() -> Bool { true }
    func includeAllNetworks() -> Bool { false }
    func registerMyInterface(_: String?) {}
    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }
    func systemCertificates() -> (any LibboxStringIteratorProtocol)? { nil }
    func usePlatformShell() -> Bool { false }
    func checkPlatformShell() throws { throw unsupported("Platform shell is not available") }
    func lookupSFTPServer() throws -> LibboxStringBox { throw unsupported("SFTP server lookup is not available") }

    func findConnectionOwner(_: Int32, sourceAddress _: String?, sourcePort _: Int32, destinationAddress _: String?, destinationPort _: Int32) throws -> LibboxConnectionOwner {
        throw unsupported("Connection owner lookup is not available")
    }

    func writeLog(_ message: String?) {
        guard let message else { return }
        singBoxLogger.info("\(message, privacy: .public)")
    }

    func writeDebugMessage(_ message: String?) {
        guard let message else { return }
        singBoxLogger.debug("\(message, privacy: .public)")
    }

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { return }
        let monitor = NWPathMonitor()
        nwMonitor = monitor
        monitor.pathUpdateHandler = { path in
            guard path.status != .unsatisfied,
                  let interface = path.availableInterfaces.first else {
                listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
                return
            }
            listener.updateDefaultInterface(interface.name, interfaceIndex: Int32(interface.index), isExpensive: path.isExpensive, isConstrained: path.isConstrained)
        }
        monitor.start(queue: DispatchQueue.global())
    }

    func closeDefaultInterfaceMonitor(_: LibboxInterfaceUpdateListenerProtocol?) throws {
        nwMonitor?.cancel()
        nwMonitor = nil
    }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        let interfaces = nwMonitor?.currentPath.availableInterfaces ?? []
        return NetworkInterfaceIterator(interfaces.map { interface in
            let result = LibboxNetworkInterface()
            result.name = interface.name
            result.index = Int32(interface.index)
            switch interface.type {
            case .wifi:
                result.type = LibboxInterfaceTypeWIFI
            case .cellular:
                result.type = LibboxInterfaceTypeCellular
            case .wiredEthernet:
                result.type = LibboxInterfaceTypeEthernet
            default:
                result.type = LibboxInterfaceTypeOther
            }
            return result
        })
    }

    func clearDNSCache() {
        guard let provider, let networkSettings else { return }
        runBlocking {
            await withCheckedContinuation { continuation in
                provider.setTunnelNetworkSettings(nil) { _ in continuation.resume() }
            }
            await withCheckedContinuation { continuation in
                provider.setTunnelNetworkSettings(networkSettings) { _ in continuation.resume() }
            }
        }
    }

    func readWIFIState() -> LibboxWIFIState? {
        #if os(iOS)
        let network = runBlocking { await NEHotspotNetwork.fetchCurrent() }
        guard let network else { return nil }
        return LibboxWIFIState(network.ssid, wifiBSSID: network.bssid)
        #elseif os(macOS)
        guard let interface = CWWiFiClient.shared().interface(),
              let ssid = interface.ssid(),
              let bssid = interface.bssid() else { return nil }
        return LibboxWIFIState(ssid, wifiBSSID: bssid)
        #else
        return nil
        #endif
    }

    func readWIFISSID() -> String? {
        #if os(iOS)
        return runBlocking { await NEHotspotNetwork.fetchCurrent()?.ssid }
        #elseif os(macOS)
        return CWWiFiClient.shared().interface()?.ssid()
        #else
        return nil
        #endif
    }

    func connectSSHAgent(_: UnsafeMutablePointer<Int32>?) throws {
        throw unsupported("SSH agent forwarding is not available")
    }

    func serviceStop() throws {}
    func serviceReload() throws {}

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        LibboxSystemProxyStatus()
    }

    func setSystemProxyEnabled(_: Bool) throws {}

    func triggerNativeCrash() throws {
        fatalError("Real Ai VPN requested a sing-box native crash")
    }

    func send(_ notification: LibboxNotification?) throws {
        guard let notification else { return }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        let request = UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func startNeighborMonitor(_: LibboxNeighborUpdateListenerProtocol?) throws {}
    func closeNeighborMonitor(_: LibboxNeighborUpdateListenerProtocol?) throws {}

    func openShellSession(_: LibboxPlatformUser?, command _: String?, environ _: (any LibboxStringIteratorProtocol)?, term _: String?, rows _: Int32, cols _: Int32) throws -> any LibboxShellSessionProtocol {
        throw unsupported("Platform shell is not available")
    }

    func readSystemSSHHostKey() throws -> LibboxStringBox {
        throw unsupported("System SSH host key is not available")
    }

    func lookupUser(_: String?) throws -> LibboxPlatformUser {
        throw unsupported("User lookup is not available")
    }

    func reset() {
        networkSettings = nil
        nwMonitor?.cancel()
        nwMonitor = nil
    }

    private func unsupported(_ message: String) -> NSError {
        NSError(domain: "SingBoxPlatformInterface", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class NetworkInterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    private var iterator: IndexingIterator<[LibboxNetworkInterface]>
    private var current: LibboxNetworkInterface?

    init(_ interfaces: [LibboxNetworkInterface]) {
        iterator = interfaces.makeIterator()
    }

    func hasNext() -> Bool {
        current = iterator.next()
        return current != nil
    }

    func next() -> LibboxNetworkInterface? {
        current
    }
}

private func runBlocking<T>(_ block: @escaping () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = BlockingResultBox<T>()
    Task.detached(priority: .userInitiated) {
        box.value = await block()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value
}

private func runBlocking<T>(_ block: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = BlockingResultBox<T>()
    Task.detached(priority: .userInitiated) {
        do {
            box.result = .success(try await block())
        } catch {
            box.result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.result.get()
}

private final class BlockingResultBox<T>: @unchecked Sendable {
    var value: T!
    var result: Result<T, Error>!
}
#else
final class SingBoxTunnelRuntime {
    init(provider _: NEPacketTunnelProvider) {}

    func start(configJSON _: String) async throws {
        throw PacketTunnelProviderError.singBoxRuntimeMissing
    }

    func stop() async {}
}
#endif
