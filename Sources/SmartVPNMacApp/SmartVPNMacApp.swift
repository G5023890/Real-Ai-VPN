import AmneziaConfig
import AppKit
import Combine
import Network
import RealVPNCore
import SwiftUI
import SmartServerSelection
import UniformTypeIdentifiers
import UserNotifications

private final class MacNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

private final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

private enum AppVisibilityMode: String, CaseIterable, Identifiable {
    case menuBarOnly
    case dockOnly
    case dockAndMenuBar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .menuBarOnly:
            return "Menu Bar only"
        case .dockOnly:
            return "Dock only"
        case .dockAndMenuBar:
            return "Dock and Menu Bar"
        }
    }

    var detail: String {
        switch self {
        case .menuBarOnly:
            return "Hide the Dock icon and keep quick controls in the menu bar."
        case .dockOnly:
            return "Show the app in Dock without the menu bar controller."
        case .dockAndMenuBar:
            return "Show the main app in Dock and keep the menu bar controller."
        }
    }

    var showsMenuBar: Bool {
        self != .dockOnly
    }

    var activationPolicy: NSApplication.ActivationPolicy {
        switch self {
        case .menuBarOnly:
            return .accessory
        case .dockOnly, .dockAndMenuBar:
            return .regular
        }
    }
}

@main
struct SmartVPNMacApp: App {
    private static let notificationDelegate = MacNotificationDelegate()
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @AppStorage("appVisibilityMode") private var appVisibilityModeRaw = AppVisibilityMode.dockAndMenuBar.rawValue
    @StateObject private var model = DashboardModel()
    @State private var showSettings = false

    init() {
        Self.applyActivationPolicy(for: Self.storedVisibilityMode())
        Self.configureNotifications()
    }

    var body: some Scene {
        Window("Real Ai VPN", id: "main") {
            DashboardView(model: model, showSettings: $showSettings)
                .frame(minWidth: 1080, minHeight: 720)
                .onAppear {
                    applyCurrentActivationPolicy()
                }
                .onChange(of: appVisibilityModeRaw) { _, _ in
                    applyCurrentActivationPolicy()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                Button("Settings...") {
                    openMainWindow()
                    showSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        menuBarScene
    }

    @SceneBuilder
    private var menuBarScene: some Scene {
        MenuBarExtra(isInserted: menuBarInserted) {
            menuBarContent
        } label: {
            MenuBarIcon(isConnected: model.vpnStatus == .connected)
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: { appVisibilityMode.showsMenuBar },
            set: { _ in }
        )
    }

    @ViewBuilder
    private var menuBarContent: some View {
        Button("Open") {
            openMainWindow()
        }

        Divider()

        Button("Connect") {
            model.connectVPN()
        }
        .disabled(model.vpnStatus.isConnectedOrConnecting)

        Button("Disconnect") {
            model.disconnectVPN()
        }
        .disabled(!model.vpnStatus.isConnectedOrConnecting)

        Divider()

        Button("Settings") {
            openMainWindow()
            showSettings = true
        }

        Divider()

        Button("Quit") {
            model.disconnectVPN()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private var appVisibilityMode: AppVisibilityMode {
        AppVisibilityMode(rawValue: appVisibilityModeRaw) ?? .dockAndMenuBar
    }

    private func applyCurrentActivationPolicy() {
        Self.applyActivationPolicy(for: appVisibilityMode)
    }

    private static func storedVisibilityMode() -> AppVisibilityMode {
        let rawValue = UserDefaults.standard.string(forKey: "appVisibilityMode")
        return rawValue.flatMap(AppVisibilityMode.init(rawValue:)) ?? .dockAndMenuBar
    }

    private static func applyActivationPolicy(for mode: AppVisibilityMode) {
        NSApplication.shared.setActivationPolicy(mode.activationPolicy)
    }

    private static func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = notificationDelegate
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

struct MenuBarIcon: View {
    var isConnected: Bool

    var body: some View {
        if isConnected, let image = NSImage(named: "real-ai-vpn-menubar-active-template") {
            Image(nsImage: configuredTemplateImage(image))
        } else if let image = NSImage(named: "real-ai-vpn-menubar-template") {
            Image(nsImage: configuredTemplateImage(image))
        } else {
            Image(systemName: "lock.shield.fill")
        }
    }

    private func configuredTemplateImage(_ image: NSImage) -> NSImage {
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }
}

struct ActiveMenuBarShieldIcon: View {
    var body: some View {
        if let image = NSImage(named: "real-ai-vpn-menubar-active-template") {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .accessibilityLabel("Real Ai VPN connected")
        } else {
            Image(systemName: "shield.fill")
                .resizable()
                .scaledToFit()
                .accessibilityLabel("Real Ai VPN connected")
        }
    }
}

struct StoredProfileQualityHistory: Codable {
    var samples: [ServerQualitySample]
}

struct StoredProbeReliabilityHistory: Codable {
    var probes: [ConnectivityProbeResult]
}

struct LocalProfileQualityHistoryStore {
    private let maxSamples = 240

    func load() -> [ServerQualitySample] {
        guard let data = try? Data(contentsOf: historyURL) else {
            return []
        }

        return ((try? JSONDecoder().decode(StoredProfileQualityHistory.self, from: data))?.samples ?? [])
            .suffix(maxSamples)
    }

    func save(_ samples: [ServerQualitySample]) {
        let trimmed = Array(samples.suffix(maxSamples))
        let payload = StoredProfileQualityHistory(samples: trimmed)
        do {
            try FileManager.default.createDirectory(
                at: historyURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(payload)
            try data.write(to: historyURL, options: [.atomic])
        } catch {
            NSLog("Real Ai VPN could not save quality history: \(error.localizedDescription)")
        }
    }

    private var historyURL: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("Real Ai VPN", isDirectory: true)
            .appendingPathComponent("profile-quality-history.json")
    }
}

struct LocalProbeReliabilityHistoryStore {
    private let maxSamples = 960

    func load() -> [ConnectivityProbeResult] {
        guard let data = try? Data(contentsOf: historyURL) else {
            return []
        }

        return ((try? JSONDecoder().decode(StoredProbeReliabilityHistory.self, from: data))?.probes ?? [])
            .suffix(maxSamples)
    }

    func save(_ probes: [ConnectivityProbeResult]) {
        let trimmed = Array(probes.suffix(maxSamples))
        let payload = StoredProbeReliabilityHistory(probes: trimmed)
        do {
            try FileManager.default.createDirectory(
                at: historyURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(payload)
            try data.write(to: historyURL, options: [.atomic])
        } catch {
            NSLog("Real Ai VPN could not save probe reliability history: \(error.localizedDescription)")
        }
    }

    private var historyURL: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("Real Ai VPN", isDirectory: true)
            .appendingPathComponent("probe-reliability-history.json")
    }
}

struct ProfileEndpoint {
    var host: String
    var port: UInt16
}

private final class ProbeCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false

    func runOnce(_ body: () -> Void) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()
        body()
    }
}

enum ConnectivityProbeRunner {
    static func tcpConnect(host: String, port: UInt16, timeout: TimeInterval = 4) async -> (succeeded: Bool, latency: Double?) {
        await withCheckedContinuation { continuation in
            let start = Date()
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? 443,
                using: .tcp
            )
            let queue = DispatchQueue(label: "RealAiVPN.TCPProbe.\(host)")
            let completionGate = ProbeCompletionGate()

            @Sendable func finish(_ result: (Bool, Double?)) {
                completionGate.runOnce {
                    connection.cancel()
                    continuation.resume(returning: result)
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish((true, Date().timeIntervalSince(start) * 1_000))
                case .failed, .cancelled:
                    finish((false, nil))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish((false, nil))
            }
        }
    }

    static func httpHead(url: URL, timeout: TimeInterval = 5) async -> (succeeded: Bool, latency: Double?) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let start = Date()

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            return ((200..<400).contains(statusCode), Date().timeIntervalSince(start) * 1_000)
        } catch {
            return (false, nil)
        }
    }

    static func fetchText(url: URL, timeout: TimeInterval = 5) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(statusCode),
                  let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    static func fetchJSONDictionary(url: URL, timeout: TimeInterval = 5) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(statusCode) else {
                return nil
            }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }
}

@MainActor
final class DashboardModel: ObservableObject {
    enum StoredConfigKind: String {
        case none = "No Config"
        case premiumToken = "Premium Token"
        case awgConfig = "AWG Config"
        case singBoxVLESSReality = "VLESS Reality"
        case unknown = "Config"
    }

    enum ProbeScenario: String, CaseIterable, Identifiable {
        case healthy = "Healthy"
        case degraded = "Degraded"
        case stalled = "Stalled"

        var id: String { rawValue }
    }

    @Published var currentRegion: RegionCode = "RU"
    @Published var homeRegion: RegionCode = "IL"
    @Published var activeServerID = "il-1"
    @Published var selectedDestination: DestinationRegion = .foreign
    @Published var scenario: ProbeScenario = .healthy
    @Published private(set) var routeDecision: RouteDecision
    @Published private(set) var healthAssessment: PreventiveHealthAssessment
    @Published private(set) var rankedServers: [RankedServer] = []
    @Published private(set) var vpnStatus: VPNConnectionStatus = .disconnected
    @Published private(set) var vpnErrorMessage: String?
    @Published private(set) var tunnelDiagnostic: TunnelDiagnosticSnapshot?
    @Published private(set) var hasAmneziaPremiumKey = false
    @Published private(set) var storedConfigKind: StoredConfigKind = .none
    @Published private(set) var configProfiles: [StoredAmneziaConfigProfile] = []
    @Published private(set) var connectedConfigProfileID: String?
    @Published private(set) var observedExitIP: String?
    @Published private(set) var observedExitCountry: String?
    @Published private(set) var monitorStatus = "Waiting for VPN connection"
    @Published private(set) var lastProbeDate: Date?
    @Published private(set) var lastRecoveryDecisionLog = ""
    @Published private(set) var routingExceptions = RoutingExceptionCollection()
    @Published var automaticFailoverEnabled = UserDefaults.standard.object(forKey: "automaticFailoverEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automaticFailoverEnabled, forKey: "automaticFailoverEnabled")
        }
    }
    @Published var killSwitchEnabled = UserDefaults.standard.object(forKey: "killSwitchEnabled") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(killSwitchEnabled, forKey: "killSwitchEnabled")
        }
    }
    @Published var activeConfigProfileID: String? {
        didSet {
            guard activeConfigProfileID != oldValue else {
                return
            }
            saveActiveProfileSelection()
        }
    }

    let servers: [SmartVPNServer] = [
        SmartVPNServer(id: "il-1", region: "IL", displayName: "Israel Prime", protocolKind: .amneziaWG, lastLatencyMilliseconds: 135),
        SmartVPNServer(id: "de-1", region: "DE", displayName: "Frankfurt Fast", protocolKind: .amneziaWG, lastLatencyMilliseconds: 82),
        SmartVPNServer(id: "nl-1", region: "NL", displayName: "Amsterdam Relay", protocolKind: .amneziaWG, lastLatencyMilliseconds: 97, healthState: .degraded)
    ]

    private let selector = SmartServerSelector()
    private let amneziaDecoder = AmneziaConfigDecoder()
    private let shadowrocketParser = ShadowrocketVLESSConfigParser()
    private let vpnManager = RealVPNProfileManager()
    private let premiumKeyStore = AmneziaPremiumKeyStore(accessGroup: AmneziaPremiumKeyStore.sharedAccessGroup)
    private let profileStore = AmneziaConfigProfileStore(accessGroup: AmneziaPremiumKeyStore.sharedAccessGroup)
    private let qualityHistoryStore = LocalProfileQualityHistoryStore()
    private let probeReliabilityHistoryStore = LocalProbeReliabilityHistoryStore()
    private let probeReliabilityAnalyzer = ProbeReliabilityAnalyzer()
    private let routingExceptionStore = RoutingExceptionStore()
    private let tunnelDiagnosticsStore = TunnelDiagnosticsStore()
    private lazy var monitor = PreventiveVPNHealthMonitor(selector: selector, reliabilityAnalyzer: probeReliabilityAnalyzer)
    private var cancellables: Set<AnyCancellable> = []
    private var qualitySamples: [ServerQualitySample] = []
    private var probeReliabilitySamples: [ConnectivityProbeResult] = []
    private var liveProbeResults: [ConnectivityProbeResult] = []
    private var monitoringTask: Task<Void, Never>?
    private var lastAutomaticFailoverDate: Date?
    private var vpnHardDegradedSince: Date?
    private var profileQuarantineUntil: [String: Date] = [:]
    private var suppressExpectedDisconnectNotification = false

    init() {
        let directReport = PathHealthReport(
            state: .healthy,
            healthScore: 1,
            successRate: 1,
            averageLatencyMilliseconds: 24,
            averagePacketLoss: 0,
            consecutiveFailures: 0,
            reason: "healthy"
        )
        let vpnReport = PathHealthReport(
            state: .healthy,
            healthScore: 1,
            successRate: 1,
            averageLatencyMilliseconds: 140,
            averagePacketLoss: 0.01,
            consecutiveFailures: 0,
            reason: "healthy"
        )
        routeDecision = RouteDecision(action: .vpn(serverID: "de-1", region: "DE"), source: "fastest-vpn-heuristic")
        healthAssessment = PreventiveHealthAssessment(
            directPath: directReport,
            vpnPath: vpnReport,
            recommendedAction: .keepCurrent(reason: "vpn-path-healthy")
        )

        seedHistory()
        migrateLegacySingleConfigIfNeeded()
        routingExceptions = routingExceptionStore.load()
        bindVPNManagerState()
        refresh()
        refreshPremiumKeyState()
        loadQualityHistory()
        loadProbeReliabilityHistory()
        startMonitoring()
        Task {
            await vpnManager.prepareProfile(configuration: vpnConfiguration)
        }
    }

    deinit {
        monitoringTask?.cancel()
    }

    var activeConfigProfile: StoredAmneziaConfigProfile? {
        guard let activeConfigProfileID else {
            return configProfiles.first
        }

        return configProfiles.first { $0.id == activeConfigProfileID } ?? configProfiles.first
    }

    var connectedConfigProfile: StoredAmneziaConfigProfile? {
        guard let connectedConfigProfileID else {
            return nil
        }

        return configProfiles.first { $0.id == connectedConfigProfileID }
    }

    var displayedConfigProfile: StoredAmneziaConfigProfile? {
        vpnStatus.isConnectedOrConnecting ? (connectedConfigProfile ?? activeConfigProfile) : activeConfigProfile
    }

    var activeConfigSummary: String {
        guard let activeConfigProfile else {
            return storedConfigKind.rawValue
        }

        if let regionCode = activeConfigProfile.regionCode {
            return "\(activeConfigProfile.displayName) · \(regionCode)"
        }

        return activeConfigProfile.displayName
    }

    var activeRouteTitle: String {
        if vpnStatus == .connected, let displayedConfigProfile {
            return "VPN \(displayedConfigProfile.regionCode ?? displayedConfigProfile.displayName)"
        }

        switch routeDecision.action {
        case .directProviderDNS:
            return "Direct Provider DNS"
        case .vpn(_, let region):
            return vpnStatus.isConnectedOrConnecting ? "VPN \(region.rawValue)" : "Planned VPN \(region.rawValue)"
        case .ask:
            return "Needs Attention"
        }
    }

    var activeRouteSource: String {
        if vpnStatus == .connected, let displayedConfigProfile {
            var parts = ["connected profile", displayedConfigProfile.displayName]
            if let endpointHost = displayedConfigProfile.endpointHost {
                parts.append(endpointHost)
            }
            if let observedExitIP {
                parts.append("exit \(observedExitIP)")
            }
            if let observedExitCountry {
                parts.append("country \(observedExitCountry)")
            }
            return parts.joined(separator: " · ")
        }

        return vpnStatus == .connected ? routeDecision.source : "\(routeDecision.source) · policy preview"
    }

    var routeConfidence: Double {
        if vpnStatus.isConnectedOrConnecting {
            return healthAssessment.vpnPath.healthScore
        }

        if let activeID = displayedConfigProfile?.id,
           let activeRank = rankedServers.first(where: { $0.server.id == activeID }) {
            return activeRank.confidence
        }

        return routeDecision.rankedServers.first?.confidence ?? rankedServers.first?.confidence ?? 0
    }

    var routeConfidenceDetail: String {
        guard let lastProbeDate else {
            return "collecting"
        }

        let age = max(0, Int(Date().timeIntervalSince(lastProbeDate)))
        let sampleCount = displayedConfigProfile.map { profile in
            qualitySamples.filter { $0.serverID == profile.id }.count
        } ?? qualitySamples.count
        return "\(sampleCount) samples · \(age)s ago"
    }

    var probeReliabilityDetail: String {
        guard let activeID = displayedConfigProfile?.id ?? (vpnStatus.isConnectedOrConnecting ? activeServerID : nil),
              let best = probeReliabilityAnalyzer.bestSummary(
                from: probeReliabilitySamples,
                serverID: activeID,
                targetKind: .vpnProtectedEndpoint
              ) else {
            return "Probe reliability is learning"
        }

        return "Best check \(best.targetID) · \(Int((best.reliabilityScore * 100).rounded()))% reliable"
    }

    var activeProfileDisplayName: String {
        displayedConfigProfile?.displayName ?? activeConfigProfile?.displayName ?? activeConfigSummary
    }

    func displayName(forServerID serverID: String) -> String {
        if let profile = configProfiles.first(where: { $0.id == serverID }) {
            return profile.displayName
        }

        return servers.first { $0.id == serverID }?.displayName ?? serverID
    }

    var context: ServerSelectionContext {
        ServerSelectionContext(
            currentRegion: currentRegion,
            homeRegion: homeRegion,
            networkKind: .wifi,
            providerASN: "AS12389",
            hourOfDay: Calendar.current.component(.hour, from: Date()),
            previousServerID: displayedConfigProfile?.id ?? activeConfigProfile?.id ?? activeServerID
        )
    }

    func refresh() {
        let servers = effectiveServers
        routeDecision = selector.decideRoute(
            destinationRegion: selectedDestination,
            context: context,
            servers: servers
        )
        rankedServers = selector.rankedServers(context: context, servers: servers)
        healthAssessment = monitor.assess(
            probes: liveProbeResults.isEmpty ? probes(for: scenario) : liveProbeResults,
            activeServerID: displayedConfigProfile?.id ?? activeConfigProfile?.id ?? activeServerID,
            context: context,
            servers: servers,
            probeHistory: probeReliabilitySamples,
            vpnIsConnected: vpnStatus.isConnectedOrConnecting,
            directPathTrust: providerProbeTrust,
            degradedHardDurationSeconds: currentHardDegradedDuration(),
            quarantinedServerIDs: activeQuarantinedProfileIDs()
        )
        updateRecoveryTracking(from: healthAssessment)
    }

    func applyRecoveryAction() {
        let wasConnected = vpnStatus.isConnectedOrConnecting

        switch healthAssessment.recommendedAction {
        case .switchServer(_, let to, _):
            switchToProfileOrServer(id: to)
            if wasConnected {
                reconnectVPN()
            }
        case .reconnect(let serverID, _), .adjustParameters(let serverID, _, _):
            switchToProfileOrServer(id: serverID)
            if wasConnected {
                reconnectVPN()
            }
        case .refreshDirectDNS:
            URLCache.shared.removeAllCachedResponses()
            URLSession.shared.reset {}
            monitorStatus = "DNS/session cache refreshed"
        case .keepCurrent, .askUser:
            break
        }

        scenario = .healthy
        refresh()
    }

    func addRoutingException(value: String, mode: RoutingExceptionMode) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return
        }

        routingExceptions.rules.append(RoutingExceptionRule(value: normalized, mode: mode))
        routingExceptionStore.save(routingExceptions)
        monitorStatus = "Routing exceptions will apply on reconnect"
    }

    func deleteRoutingException(id: String) {
        routingExceptions.rules.removeAll { $0.id == id }
        routingExceptionStore.save(routingExceptions)
        monitorStatus = "Routing exceptions will apply on reconnect"
    }

    func setRoutingExceptionEnabled(id: String, isEnabled: Bool) {
        guard let index = routingExceptions.rules.firstIndex(where: { $0.id == id }) else {
            return
        }

        routingExceptions.rules[index].isEnabled = isEnabled
        routingExceptionStore.save(routingExceptions)
        monitorStatus = "Routing exceptions will apply on reconnect"
    }

    func selectConfigProfile(id: String?) {
        activeConfigProfileID = id
    }

    func reconnectConfigProfile(id: String) {
        let wasConnectedOrConnecting = vpnStatus.isConnectedOrConnecting
        selectConfigProfile(id: id)

        guard let profile = activeConfigProfile else {
            vpnErrorMessage = "Could not reconnect: profile is missing."
            return
        }

        monitorStatus = wasConnectedOrConnecting
            ? "Reconnecting \(profile.displayName)"
            : "Connecting \(profile.displayName)"

        if wasConnectedOrConnecting {
            vpnStatus = .disconnecting
            suppressExpectedDisconnectNotification = true
            vpnManager.disconnect()
            Task {
                try? await Task.sleep(for: .seconds(1))
                connectVPN()
            }
        } else {
            connectVPN()
        }
    }

    func connectVPN() {
        guard !vpnStatus.isConnectedOrConnecting else {
            return
        }

        vpnStatus = .connecting
        vpnErrorMessage = nil
        Task {
            let profileForConnect = activeConfigProfile
            let amneziaKey = profileForConnect?.config ?? (try? premiumKeyStore.read())
            guard let amneziaKey, !amneziaKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                vpnErrorMessage = "Import an AmneziaWG .conf profile in Settings before connecting."
                vpnStatus = .disconnected
                return
            }

            do {
                try validateConfigForConnect(amneziaKey, profileKind: profileForConnect?.kind)
            } catch {
                vpnErrorMessage = "The saved Amnezia config cannot be used yet: \(error.localizedDescription)"
                vpnStatus = .disconnected
                return
            }

            connectedConfigProfileID = profileForConnect?.id
            observedExitIP = nil
            observedExitCountry = nil
            if let profileForConnect {
                NSLog("RealAiVPN macOS Connect requested profile=%@ kind=%@ endpoint=%@ id=%@",
                      profileForConnect.displayName,
                      profileForConnect.kind.rawValue,
                      profileForConnect.endpointHost ?? "unknown",
                      profileForConnect.id)
            }
            await vpnManager.connect(
                configuration: vpnConfiguration(for: profileForConnect),
                transientAmneziaKey: amneziaKey,
                routingExceptions: routingExceptions
            )
            tunnelDiagnostic = tunnelDiagnosticsStore.load()
        }
    }

    func disconnectVPN() {
        guard vpnStatus.isConnectedOrConnecting else {
            return
        }

        suppressExpectedDisconnectNotification = true
        vpnStatus = .disconnecting
        vpnManager.disconnect()
    }

    func reconnectVPN() {
        guard vpnStatus.isConnectedOrConnecting else {
            connectVPN()
            return
        }

        vpnStatus = .disconnecting
        suppressExpectedDisconnectNotification = true
        vpnManager.disconnect()
        Task {
            try? await Task.sleep(for: .seconds(2))
            connectVPN()
        }
    }

    func toggleVPN() {
        if vpnStatus.isConnectedOrConnecting {
            disconnectVPN()
        } else {
            connectVPN()
        }
    }

    func saveAmneziaPremiumKey(_ key: String) -> String? {
        do {
            let shadowrocketEntries = (try? shadowrocketParser.parseEntries(key)) ?? []
            if let entry = shadowrocketEntries.first {
                try upsertShadowrocketEntries(
                    shadowrocketEntries,
                    fallbackName: entry.profile.title,
                    makeFirstActive: true
                )
                refreshPremiumKeyState()
                vpnErrorMessage = nil
                return nil
            }

            let decoded = try amneziaDecoder.decodeImportedWireGuardConfig(from: key)
            try premiumKeyStore.save(key)
            let profile = makeProfile(
                name: "Manual Config",
                rawConfig: key,
                decodedConfig: decoded
            )
            try profileStore.upsert(profile)
            refreshPremiumKeyState()
            vpnErrorMessage = nil
            return nil
        } catch {
            refreshPremiumKeyState()
            return "The Amnezia config cannot be used yet: \(error.localizedDescription)"
        }
    }

    func importAmneziaConfigProfile(name: String, rawConfig: String) -> String? {
        importAmneziaConfigProfileSync(name: name, rawConfig: rawConfig)
    }

    func importAmneziaConfigProfile(name: String, rawConfig: String) async -> String? {
        do {
            if let subscriptionURL = try shadowrocketParser.subscriptionURL(from: rawConfig) {
                let subscriptionText = try await fetchSubscription(from: subscriptionURL)
                let entries = try shadowrocketParser.parseEntries(subscriptionText)
                try upsertShadowrocketEntries(entries, fallbackName: name, makeFirstActive: true)
                refreshPremiumKeyState()
                vpnErrorMessage = nil
                return nil
            }

            return importAmneziaConfigProfileSync(name: name, rawConfig: rawConfig)
        } catch {
            refreshPremiumKeyState()
            return "The subscription cannot be imported yet: \(error.localizedDescription)"
        }
    }

    private func importAmneziaConfigProfileSync(name: String, rawConfig: String) -> String? {
        do {
            let shadowrocketEntries = (try? shadowrocketParser.parseEntries(rawConfig)) ?? []
            if !shadowrocketEntries.isEmpty {
                try upsertShadowrocketEntries(
                    shadowrocketEntries,
                    fallbackName: name,
                    makeFirstActive: true
                )
                refreshPremiumKeyState()
                vpnErrorMessage = nil
                return nil
            }

            let decoded = try amneziaDecoder.decodeImportedWireGuardConfig(from: rawConfig)
            let profile = makeProfile(name: name, rawConfig: rawConfig, decodedConfig: decoded)
            try profileStore.upsert(profile)
            try premiumKeyStore.save(rawConfig)
            refreshPremiumKeyState()
            vpnErrorMessage = nil
            return nil
        } catch {
            refreshPremiumKeyState()
            return "The config cannot be used yet as AmneziaWG or Shadowrocket VLESS/Reality: \(error.localizedDescription)"
        }
    }

    private func fetchSubscription(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let response = response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            throw URLError(.badServerResponse)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func upsertShadowrocketEntries(
        _ entries: [ShadowrocketVLESSProfileEntry],
        fallbackName: String,
        makeFirstActive: Bool
    ) throws {
        for (index, entry) in entries.enumerated() {
            let name = entry.profile.title.isEmpty ? fallbackName : entry.profile.title
            let profile = makeShadowrocketProfile(
                name: entries.count == 1 ? name : "\(name)",
                rawConfig: entry.rawConfig,
                shadowrocketConfig: entry.profile
            )
            try profileStore.upsert(profile, makeActive: makeFirstActive && index == 0)
        }
    }

    func deleteAmneziaPremiumKey() -> String? {
        do {
            try premiumKeyStore.delete()
            try profileStore.deleteAll()
            refreshPremiumKeyState()
            return nil
        } catch {
            refreshPremiumKeyState()
            return error.localizedDescription
        }
    }

    func loadAmneziaPremiumKeyForEditing() -> String {
        activeConfigProfile?.config ?? (try? premiumKeyStore.read()) ?? ""
    }

    func deleteActiveConfigProfile() -> String? {
        guard let id = activeConfigProfile?.id else {
            return deleteAmneziaPremiumKey()
        }

        return deleteConfigProfile(id: id)
    }

    func renameConfigProfile(id: String, displayName: String) -> String? {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return "Profile name cannot be empty."
        }

        do {
            try profileStore.renameProfile(id: id, displayName: trimmedName)
            refreshPremiumKeyState()
            monitorStatus = "Renamed profile to \(trimmedName)"
            return nil
        } catch {
            refreshPremiumKeyState()
            return error.localizedDescription
        }
    }

    func deleteConfigProfile(id: String) -> String? {
        let deletedName = configProfiles.first { $0.id == id }?.displayName ?? "profile"
        let wasConnected = vpnStatus.isConnectedOrConnecting
        let deletingActive = activeConfigProfile?.id == id
        let deletingConnected = connectedConfigProfileID == id

        do {
            try profileStore.deleteProfile(id: id)
            refreshPremiumKeyState()
            if configProfiles.isEmpty {
                if wasConnected {
                    suppressExpectedDisconnectNotification = true
                    vpnManager.disconnect()
                }
                connectedConfigProfileID = nil
                monitorStatus = "Deleted \(deletedName). Import a profile to connect."
                return nil
            }

            if wasConnected, deletingActive || deletingConnected {
                connectedConfigProfileID = nil
                suppressExpectedDisconnectNotification = true
                vpnStatus = .disconnecting
                vpnManager.disconnect()
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    connectVPN()
                }
                monitorStatus = "Deleted \(deletedName). Reconnecting \(activeConfigSummary)."
            } else {
                monitorStatus = "Deleted \(deletedName). Active profile is \(activeConfigSummary)."
            }
            return nil
        } catch {
            refreshPremiumKeyState()
            return error.localizedDescription
        }
    }

    private func syncVPNState() {
        vpnStatus = vpnManager.status
        vpnErrorMessage = userFacingVPNError(vpnManager.lastErrorMessage)
    }

    private func bindVPNManagerState() {
        vpnManager.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.handleVPNStatusChange(status)
            }
            .store(in: &cancellables)

        vpnManager.$lastErrorMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                guard let self else {
                    return
                }
                if self.vpnStatus == .connected {
                    self.vpnErrorMessage = nil
                    self.tunnelDiagnostic = nil
                } else {
                    self.vpnErrorMessage = self.userFacingVPNError(message)
                    self.tunnelDiagnostic = self.tunnelDiagnosticsStore.load()
                }
            }
            .store(in: &cancellables)
    }

    private func handleVPNStatusChange(_ status: VPNConnectionStatus) {
        let previousStatus = vpnStatus
        let droppedProfile = activeProfileDisplayName
        vpnStatus = status

        if status == .connected {
            vpnErrorMessage = nil
            tunnelDiagnostic = nil
        }

        guard status == .disconnected else {
            return
        }

        connectedConfigProfileID = nil
        observedExitIP = nil
        observedExitCountry = nil

        if suppressExpectedDisconnectNotification {
            suppressExpectedDisconnectNotification = false
            return
        }

        if previousStatus == .connected || previousStatus == .reasserting {
            notifyTunnelDropped(profile: droppedProfile)
        }
    }

    private func userFacingVPNError(_ message: String?) -> String? {
        guard let message else {
            return nil
        }

        if message.localizedCaseInsensitiveContains("permission denied") {
            return "VPN profile needs the Packet Tunnel Extension target before macOS will allow Connect."
        }

        return message
    }

    private func refreshPremiumKeyState() {
        let collection = (try? profileStore.load()) ?? AmneziaConfigProfileCollection()
        configProfiles = collection.profiles
        activeConfigProfileID = collection.activeProfile?.id

        let stored = activeConfigProfile?.config ?? (try? premiumKeyStore.read()) ?? nil
        hasAmneziaPremiumKey = stored?.isEmpty == false
        storedConfigKind = stored.map(configKind(for:)) ?? .none
    }

    private func configKind(for value: String) -> StoredConfigKind {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .none
        }

        if trimmed.localizedCaseInsensitiveContains("[Interface]"),
           trimmed.localizedCaseInsensitiveContains("[Peer]") {
            return .awgConfig
        }

        if (try? shadowrocketParser.parseEntries(trimmed))?.isEmpty == false {
            return .singBoxVLESSReality
        }

        if trimmed.hasPrefix("vpn://") {
            return .premiumToken
        }

        return .unknown
    }

    private func validateConfigForConnect(_ value: String, profileKind: StoredAmneziaConfigProfile.Kind?) throws {
        if profileKind == .singBoxVLESSReality {
            let entries = try shadowrocketParser.parseEntries(value)
            if entries.isEmpty {
                throw ShadowrocketVLESSConfigError.noSupportedProfiles
            }
            return
        }

        if (try? shadowrocketParser.parseEntries(value))?.isEmpty == false {
            return
        }

        _ = try amneziaDecoder.decodeImportedWireGuardConfig(from: value)
    }

    private var vpnConfiguration: VPNProfileConfiguration {
        vpnConfiguration(for: activeConfigProfile)
    }

    private func vpnConfiguration(for profile: StoredAmneziaConfigProfile?) -> VPNProfileConfiguration {
        let server = servers.first { $0.id == activeServerID } ?? servers[0]
        return VPNProfileConfiguration(
            localizedDescription: localizedVPNDescription(for: profile),
            providerBundleIdentifier: providerBundleIdentifier(for: profile),
            serverID: profile?.id ?? server.id,
            regionCode: profile?.regionCode ?? server.region.rawValue,
            killSwitchEnabled: killSwitchEnabled
        )
    }

    private func localizedVPNDescription(for profile: StoredAmneziaConfigProfile?) -> String {
        profile?.kind == .singBoxVLESSReality ? "Real Ai VPN VLESS" : "Real Ai VPN AWG"
    }

    private func providerBundleIdentifier(for profile: StoredAmneziaConfigProfile?) -> String {
        profile?.kind == .singBoxVLESSReality
            ? "com.codex.RealAiVPN.SingBoxPacketTunnel"
            : "com.codex.RealAiVPN.PacketTunnel"
    }

    private var effectiveServers: [SmartVPNServer] {
        guard !configProfiles.isEmpty else {
            return servers
        }

        return configProfiles.map { profile in
            SmartVPNServer(
                id: profile.id,
                region: RegionCode(profile.regionCode ?? "ZZ"),
                displayName: profile.displayName,
                protocolKind: profile.kind == .singBoxVLESSReality ? .singBox : .amneziaWG,
                lastLatencyMilliseconds: lastLatency(for: profile.id),
                healthState: .healthy
            )
        }
    }

    private func lastLatency(for profileID: String) -> Double? {
        qualitySamples.last { $0.serverID == profileID }?.latencyMilliseconds
    }

    private func switchToProfileOrServer(id: String) {
        if configProfiles.contains(where: { $0.id == id }) {
            selectConfigProfile(id: id)
        } else {
            activeServerID = id
        }
    }

    private func activeQuarantinedProfileIDs(now: Date = Date()) -> Set<String> {
        profileQuarantineUntil = profileQuarantineUntil.filter { $0.value > now }
        return Set(profileQuarantineUntil.keys)
    }

    private func currentHardDegradedDuration(now: Date = Date()) -> TimeInterval {
        guard let vpnHardDegradedSince else {
            return 0
        }

        return now.timeIntervalSince(vpnHardDegradedSince)
    }

    private func updateRecoveryTracking(from assessment: PreventiveHealthAssessment, now: Date = Date()) {
        lastRecoveryDecisionLog = assessment.decisionLog
        if assessment.vpnPath.state == .degradedHard {
            vpnHardDegradedSince = vpnHardDegradedSince ?? now
        } else {
            vpnHardDegradedSince = nil
        }
    }

    private func quarantineProfile(id: String, until date: Date = Date().addingTimeInterval(300)) {
        profileQuarantineUntil[id] = date
    }

    private func makeProfile(name: String, rawConfig: String, decodedConfig: AmneziaWireGuardConfig) -> StoredAmneziaConfigProfile {
        let region = inferRegion(from: name) ?? inferRegion(from: decodedConfig.endpoint)
        let endpointHost = decodedConfig.endpoint.split(separator: ":").first.map(String.init)
        var displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if displayName.lowercased().hasSuffix(".conf") {
            displayName.removeLast(".conf".count)
        }

        return StoredAmneziaConfigProfile(
            displayName: displayName.isEmpty ? "Imported Config" : displayName,
            kind: .awgConfig,
            regionCode: region,
            endpointHost: endpointHost,
            config: rawConfig
        )
    }

    private func makeShadowrocketProfile(
        name: String,
        rawConfig: String,
        shadowrocketConfig: ShadowrocketVLESSConfig
    ) -> StoredAmneziaConfigProfile {
        var displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if displayName.lowercased().hasSuffix(".json") {
            displayName.removeLast(".json".count)
        }
        if displayName.isEmpty {
            displayName = shadowrocketConfig.title.isEmpty ? "VLESS Reality" : shadowrocketConfig.title
        }

        return StoredAmneziaConfigProfile(
            displayName: displayName,
            kind: .singBoxVLESSReality,
            regionCode: shadowrocketConfig.regionCode ?? inferRegion(from: displayName),
            endpointHost: shadowrocketConfig.host,
            config: rawConfig
        )
    }

    private func inferRegion(from value: String) -> String? {
        let uppercased = value.uppercased()
        for token in ["IL", "DE", "NL", "EE", "CH", "RU", "US", "GB", "FR"] where uppercased.contains(token) {
            return token
        }

        return nil
    }

    private func saveActiveProfileSelection() {
        do {
            try profileStore.setActiveProfile(id: activeConfigProfileID)
            refreshPremiumKeyState()
            refresh()
        } catch {
            vpnErrorMessage = error.localizedDescription
        }
    }

    private func migrateLegacySingleConfigIfNeeded() {
        guard ((try? profileStore.load().profiles.isEmpty) ?? true),
              let legacy = try? premiumKeyStore.read(),
              let decoded = try? amneziaDecoder.decodeImportedWireGuardConfig(from: legacy) else {
            return
        }

        let profile = makeProfile(name: "Imported Config", rawConfig: legacy, decodedConfig: decoded)
        try? profileStore.upsert(profile)
    }

    private func seedHistory() {
        selector.record(.sample(serverID: "il-1", region: "IL", latency: 142, handshake: 260, loss: 0.01))
        selector.record(.sample(serverID: "de-1", region: "DE", latency: 62, handshake: 120, loss: 0))
        selector.record(.sample(serverID: "nl-1", region: "NL", latency: 96, handshake: 220, loss: 0.04, failures: 1))
    }

    private func loadQualityHistory() {
        qualitySamples = qualityHistoryStore.load()
        qualitySamples.forEach { selector.record($0) }
        refresh()
    }

    private func loadProbeReliabilityHistory() {
        probeReliabilitySamples = probeReliabilityHistoryStore.load()
        refresh()
    }

    private func startMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runMonitoringCycle()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func runMonitoringCycle() async {
        guard !configProfiles.isEmpty else {
            monitorStatus = "Import profiles to enable live probes"
            return
        }

        let profiles = configProfiles
        let activeID = displayedConfigProfile?.id
        var assessmentProbes: [ConnectivityProbeResult] = []
        monitorStatus = vpnStatus.isConnectedOrConnecting ? "Running live probes" : "VPN disconnected; probing standby endpoints"

        assessmentProbes.append(contentsOf: await directProviderProbes())

        for profile in profiles {
            guard let endpoint = endpoint(for: profile) else {
                continue
            }

            let tcp = await ConnectivityProbeRunner.tcpConnect(host: endpoint.host, port: endpoint.port)
            let isActive = profile.id == activeID
            let latency = tcp.latency ?? 3_000
            let sample = ServerQualitySample(
                serverID: profile.id,
                region: RegionCode(profile.regionCode ?? "ZZ"),
                networkKind: .wifi,
                latencyMilliseconds: latency,
                packetLoss: tcp.succeeded ? 0 : 1,
                handshakeMilliseconds: latency,
                recentFailureCount: tcp.succeeded ? 0 : 1
            )
            recordQualitySample(sample)

            let probe = ConnectivityProbeResult(
                targetID: isActive ? "active-endpoint" : "standby-endpoint",
                targetKind: .vpnServer,
                serverID: profile.id,
                region: RegionCode(profile.regionCode ?? "ZZ"),
                method: .tcpConnect,
                succeeded: tcp.succeeded,
                latencyMilliseconds: tcp.latency,
                packetLoss: tcp.succeeded ? 0 : 1
            )
            if isActive {
                assessmentProbes.append(probe)
            }
        }

        if vpnStatus.isConnectedOrConnecting, let activeID {
            assessmentProbes.append(contentsOf: await vpnProtectedProbes(serverID: activeID))
            assessmentProbes.append(await exitIPProbe(serverID: activeID))
            assessmentProbes.append(await exitCountryProbe(serverID: activeID))
        }

        liveProbeResults = assessmentProbes
        recordProbeReliabilitySamples(assessmentProbes)
        lastProbeDate = Date()
        refresh()
        await applyAutomaticFailoverIfNeeded()
    }

    private var providerProbeTrust: PathProbeTrust {
        vpnStatus.isConnectedOrConnecting ? .untrustedWhileVPNActive : .trusted
    }

    private func directProviderProbes() async -> [ConnectivityProbeResult] {
        let targets: [(String, ProbeMethod, () async -> (succeeded: Bool, latency: Double?))] = [
            ("ru-ya", .httpHead, { await ConnectivityProbeRunner.httpHead(url: URL(string: "https://ya.ru")!) }),
            ("ru-mos", .httpHead, { await ConnectivityProbeRunner.httpHead(url: URL(string: "https://www.mos.ru")!) }),
            ("provider-dns-tcp", .tcpConnect, { await ConnectivityProbeRunner.tcpConnect(host: "77.88.8.8", port: 53, timeout: 3) })
        ]

        var probes: [ConnectivityProbeResult] = []
        for target in targets {
            let result = await target.2()
            probes.append(ConnectivityProbeResult(
                targetID: target.0,
                targetKind: target.0 == "provider-dns-tcp" ? .dnsResolver : .directEndpoint,
                method: target.1,
                succeeded: result.succeeded,
                latencyMilliseconds: result.latency,
                packetLoss: result.succeeded ? 0 : 1
            ))
        }

        return probes
    }

    private func vpnProtectedProbes(serverID: String) async -> [ConnectivityProbeResult] {
        let targets: [(String, ProbeMethod, () async -> (succeeded: Bool, latency: Double?))] = [
            ("foreign-gstatic-204", .httpHead, { await ConnectivityProbeRunner.httpHead(url: URL(string: "https://www.gstatic.com/generate_204")!) }),
            ("foreign-cloudflare-204", .httpHead, { await ConnectivityProbeRunner.httpHead(url: URL(string: "https://cp.cloudflare.com/generate_204")!) }),
            ("foreign-cloudflare-tcp", .tcpConnect, { await ConnectivityProbeRunner.tcpConnect(host: "1.1.1.1", port: 443, timeout: 3) })
        ]

        var probes: [ConnectivityProbeResult] = []
        for target in targets {
            let result = await target.2()
            probes.append(ConnectivityProbeResult(
                targetID: target.0,
                targetKind: .vpnProtectedEndpoint,
                serverID: serverID,
                method: target.1,
                succeeded: result.succeeded,
                latencyMilliseconds: result.latency,
                packetLoss: result.succeeded ? 0 : 1
            ))
        }

        return probes
    }

    private func updateObservedExitIP() async {
        guard vpnStatus.isConnectedOrConnecting else {
            observedExitIP = nil
            observedExitCountry = nil
            return
        }

        observedExitIP = await ConnectivityProbeRunner.fetchText(url: URL(string: "https://api.ipify.org")!)
        observedExitCountry = await fetchExitCountry()
    }

    private func exitIPProbe(serverID: String) async -> ConnectivityProbeResult {
        guard vpnStatus.isConnectedOrConnecting else {
            observedExitIP = nil
            observedExitCountry = nil
            return ConnectivityProbeResult(
                targetID: "exit-ip",
                targetKind: .vpnProtectedEndpoint,
                serverID: serverID,
                method: .httpHead,
                succeeded: false,
                packetLoss: 1
            )
        }

        let started = Date()
        let exitIP = await ConnectivityProbeRunner.fetchText(url: URL(string: "https://api.ipify.org")!)
        observedExitIP = exitIP
        return ConnectivityProbeResult(
            targetID: "exit-ip",
            targetKind: .vpnProtectedEndpoint,
            serverID: serverID,
            method: .httpHead,
            succeeded: exitIP != nil,
            latencyMilliseconds: Date().timeIntervalSince(started) * 1_000,
            packetLoss: exitIP == nil ? 1 : 0
        )
    }

    private func exitCountryProbe(serverID: String) async -> ConnectivityProbeResult {
        guard vpnStatus.isConnectedOrConnecting else {
            observedExitCountry = nil
            return ConnectivityProbeResult(
                targetID: "exit-country",
                targetKind: .vpnProtectedEndpoint,
                serverID: serverID,
                method: .httpGet,
                succeeded: false,
                packetLoss: 1
            )
        }

        let started = Date()
        let country = await fetchExitCountry()
        observedExitCountry = country
        return ConnectivityProbeResult(
            targetID: "exit-country",
            targetKind: .vpnProtectedEndpoint,
            serverID: serverID,
            method: .httpGet,
            succeeded: country != nil,
            latencyMilliseconds: Date().timeIntervalSince(started) * 1_000,
            packetLoss: country == nil ? 1 : 0
        )
    }

    private func fetchExitCountry() async -> String? {
        guard let json = await ConnectivityProbeRunner.fetchJSONDictionary(url: URL(string: "https://api.country.is")!),
              let country = json["country"] as? String else {
            return nil
        }
        let normalized = country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func endpoint(for profile: StoredAmneziaConfigProfile) -> ProfileEndpoint? {
        if profile.kind == .singBoxVLESSReality,
           let parsed = try? shadowrocketParser.parse(profile.config) {
            return ProfileEndpoint(host: parsed.host, port: parsed.port)
        }

        guard let decoded = try? amneziaDecoder.decodeImportedWireGuardConfig(from: profile.config) else {
            return profile.endpointHost.map { ProfileEndpoint(host: $0, port: 51820) }
        }

        return endpoint(from: decoded.endpoint)
    }

    private func endpoint(from rawEndpoint: String) -> ProfileEndpoint? {
        let trimmed = rawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
            let parts = trimmed.split(separator: "]", maxSplits: 1).map(String.init)
            guard let host = parts.first?.dropFirst(), let portPart = parts.last?.dropFirst().split(separator: ":").last,
                  let port = UInt16(portPart) else {
                return nil
            }
            return ProfileEndpoint(host: String(host), port: port)
        }

        let parts = trimmed.split(separator: ":")
        guard let host = parts.first else {
            return nil
        }

        let port = parts.dropFirst().last.flatMap { UInt16($0) } ?? 51820
        return ProfileEndpoint(host: String(host), port: port)
    }

    private func recordQualitySample(_ sample: ServerQualitySample) {
        selector.record(sample)
        qualitySamples.append(sample)
        qualitySamples = Array(qualitySamples.suffix(240))
        qualityHistoryStore.save(qualitySamples)
    }

    private func recordProbeReliabilitySamples(_ probes: [ConnectivityProbeResult]) {
        probeReliabilitySamples.append(contentsOf: probes)
        probeReliabilitySamples = Array(probeReliabilitySamples.suffix(960))
        probeReliabilityHistoryStore.save(probeReliabilitySamples)
    }

    private func applyAutomaticFailoverIfNeeded() async {
        guard automaticFailoverEnabled, vpnStatus.isConnectedOrConnecting else {
            return
        }

        if let lastAutomaticFailoverDate,
           Date().timeIntervalSince(lastAutomaticFailoverDate) < 90 {
            return
        }

        guard case .switchServer(_, let to, let reason) = healthAssessment.recommendedAction,
              configProfiles.contains(where: { $0.id == to }),
              to != displayedConfigProfile?.id else {
            return
        }

        if let from = displayedConfigProfile?.id {
            quarantineProfile(id: from)
        }
        let oldProfile = activeConfigSummary
        switchToProfileOrServer(id: to)
        lastAutomaticFailoverDate = Date()
        notifyFailover(from: oldProfile, to: activeConfigSummary, reason: reason)

        suppressExpectedDisconnectNotification = true
        disconnectVPN()
        try? await Task.sleep(for: .seconds(2))
        connectVPN()
    }

    private func notifyTunnelDropped(profile: String) {
        let content = UNMutableNotificationContent()
        content.title = "Real Ai VPN disconnected"
        content.body = "Tunnel dropped or reset for \(profile)."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "real-ai-vpn-macos-disconnect-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func notifyFailover(from oldProfile: String, to newProfile: String, reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "Real Ai VPN switched profile"
        content.body = "\(oldProfile) → \(newProfile). \(reason)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "real-ai-vpn-macos-failover-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func probes(for scenario: ProbeScenario) -> [ConnectivityProbeResult] {
        switch scenario {
        case .healthy:
            return .healthyDirect + .healthyVPN(serverID: activeServerID)
        case .degraded:
            return .healthyDirect + .degradedVPN(serverID: activeServerID)
        case .stalled:
            return .healthyDirect + .downVPN(serverID: activeServerID)
        }
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @Binding var showSettings: Bool

    private var buildLabel: String {
        Bundle.main.object(forInfoDictionaryKey: "RAIVPNBuildLabel") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "dev"
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.11, blue: 0.15),
                    Color(red: 0.12, green: 0.18, blue: 0.22),
                    Color(red: 0.16, green: 0.13, blue: 0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                titleBar
                Divider().opacity(0.16)
                content
            }
        }
        .foregroundStyle(.white)
    }

    private var titleBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 24, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.teal)

            VStack(alignment: .leading, spacing: 2) {
                Text("Real Ai VPN")
                    .font(.system(size: 18, weight: .semibold))
                Text("\(titleSubtitle) · v\(buildLabel)")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.62))
            }

            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 42, height: 30)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                model.toggleVPN()
            } label: {
                Label(connectButtonTitle, systemImage: connectButtonSymbol)
                    .frame(width: 132, height: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(model.vpnStatus.isConnectedOrConnecting ? .red : .teal)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial.opacity(0.62))
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
    }

    private var content: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                ConnectionPanel(model: model)
                    .frame(maxWidth: .infinity, minHeight: 260)

                HealthPanel(model: model)
                    .frame(width: 320)
                    .frame(minHeight: 260)
            }

            HStack(alignment: .top, spacing: 16) {
                ServerRankingPanel(model: model)
                    .frame(maxWidth: .infinity, minHeight: 300)

                RecoveryPanel(model: model)
                    .frame(width: 320)
                    .frame(minHeight: 300)
            }
        }
        .padding(24)
    }

    private var activeServerName: String {
        model.servers.first { $0.id == model.activeServerID }?.displayName ?? model.activeServerID
    }

    private var titleSubtitle: String {
        "VPN \(model.vpnStatus.rawValue.capitalized) · RU network · IL home · \(activeServerName)"
    }

    private var connectButtonTitle: String {
        model.vpnStatus.isConnectedOrConnecting ? "Disconnect" : "Connect"
    }

    private var connectButtonSymbol: String {
        model.vpnStatus.isConnectedOrConnecting ? "stop.fill" : "power"
    }
}

struct ConnectionPanel: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        Panel(title: "Route", symbol: "point.topleft.down.curvedto.point.bottomright.up") {
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.activeRouteTitle)
                        .font(.system(size: 34, weight: .bold))
                        .minimumScaleFactor(0.75)
                        .lineLimit(1)

                    Text(model.activeRouteSource)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))

                    HStack(spacing: 8) {
                        CapsuleLabel(text: "Current \(model.currentRegion.rawValue)", symbol: "location.fill", tint: .cyan)
                        CapsuleLabel(text: "Home \(model.homeRegion.rawValue)", symbol: "house.fill", tint: .mint)
                        CapsuleLabel(text: model.vpnStatus.rawValue.capitalized, symbol: "powerplug.fill", tint: statusTint)
                        if model.hasAmneziaPremiumKey {
                            CapsuleLabel(text: model.activeConfigSummary, symbol: "key.fill", tint: .yellow)
                        }
                    }

                    if let error = model.vpnErrorMessage {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(error)
                                .lineLimit(2)
                            if let diagnostic = model.tunnelDiagnostic {
                                Text("\(diagnostic.stage): \(diagnostic.message)")
                                    .lineLimit(2)
                            }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .padding(.top, 4)
                    } else if !model.vpnStatus.isConnectedOrConnecting {
                        Text("Policy preview only. The packet tunnel is not active.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange.opacity(0.92))
                            .lineLimit(2)
                            .padding(.top, 4)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    Gauge(value: gaugeValue) {
                        Text("Confidence")
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(.teal)
                    .frame(width: 92, height: 92)

                    Text("\(Int(gaugeValue * 100))%")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.74))

                    Text(model.routeConfidenceDetail)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }
            }
        }
    }

    private var gaugeValue: Double {
        model.routeConfidence
    }

    private var statusTint: Color {
        switch model.vpnStatus {
        case .connected:
            return .mint
        case .connecting, .reasserting:
            return .yellow
        case .disconnecting:
            return .orange
        case .invalid, .disconnected, .unknown:
            return .orange
        }
    }
}

struct HealthPanel: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        Panel(title: "Health", symbol: "waveform.path.ecg") {
            VStack(spacing: 12) {
                HealthRow(title: "Provider", report: model.healthAssessment.directPath, tint: .cyan)
                if model.vpnStatus.isConnectedOrConnecting {
                    HealthRow(title: "Tunnel", report: model.healthAssessment.vpnPath, tint: .teal)
                } else {
                    StatusRow(
                        title: "Tunnel",
                        detail: "not connected",
                        state: "Offline",
                        value: "0%",
                        color: .orange
                    )
                }

                Text(model.monitorStatus)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(model.probeReliabilityDetail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

struct ServerRankingPanel: View {
    @ObservedObject var model: DashboardModel
    @State private var showPasteImport = false
    @State private var showConfImporter = false
    @State private var showJSONImporter = false
    @State private var renamingProfile: StoredAmneziaConfigProfile?
    @State private var deletingProfile: StoredAmneziaConfigProfile?
    @State private var actionMessage: String?

    var body: some View {
        Panel(
            title: model.configProfiles.isEmpty ? "Servers" : "Imported Profiles",
            symbol: "server.rack"
        ) {
            if !model.configProfiles.isEmpty {
                profileImportMenu
            }
        } content: {
            if model.configProfiles.isEmpty {
                rankedServerRows
            } else {
                importedProfileRows
            }
        }
        .sheet(isPresented: $showPasteImport) {
            ProfilePasteImportSheet { name, rawConfig in
                Task {
                    if let error = await model.importAmneziaConfigProfile(name: name, rawConfig: rawConfig) {
                        actionMessage = error
                    } else {
                        actionMessage = "Imported \(name.isEmpty ? "Pasted Profile" : name) as active profile."
                    }
                }
            }
        }
        .sheet(item: $renamingProfile) { profile in
            ProfileRenameSheet(profile: profile) { newName in
                if let error = model.renameConfigProfile(id: profile.id, displayName: newName) {
                    actionMessage = error
                } else {
                    actionMessage = "Renamed profile to \(newName)."
                }
            }
        }
        .confirmationDialog(
            "Delete Profile",
            isPresented: Binding(
                get: { deletingProfile != nil },
                set: { if !$0 { deletingProfile = nil } }
            ),
            presenting: deletingProfile
        ) { profile in
            Button("Delete \(profile.displayName)", role: .destructive) {
                if let error = model.deleteConfigProfile(id: profile.id) {
                    actionMessage = error
                } else {
                    actionMessage = "Deleted \(profile.displayName)."
                }
                deletingProfile = nil
            }
            Button("Cancel", role: .cancel) {
                deletingProfile = nil
            }
        } message: { profile in
            Text("If this profile is connected, Real Ai VPN will switch to the next available profile automatically.")
        }
        .fileImporter(
            isPresented: $showConfImporter,
            allowedContentTypes: [.plainText, .data, UTType(filenameExtension: "conf") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            importFileResult(result)
        }
        .fileImporter(
            isPresented: $showJSONImporter,
            allowedContentTypes: [.json, .data],
            allowsMultipleSelection: false
        ) { result in
            importFileResult(result)
        }
    }

    private var rankedServerRows: some View {
        VStack(spacing: 10) {
            ForEach(model.rankedServers, id: \.server.id) { ranked in
                HStack(spacing: 12) {
                    Image(systemName: ranked.server.id == model.activeServerID ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(ranked.server.id == model.activeServerID ? .teal : .white.opacity(0.38))
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(ranked.server.displayName)
                            .font(.system(size: 14, weight: .semibold))
                        Text("\(ranked.server.region.rawValue) · \(ranked.reason)")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.62))
                    }

                    Spacer()

                    ProgressView(value: ranked.score)
                        .progressViewStyle(.linear)
                        .tint(.teal)
                        .frame(width: 128)

                    Text("\(Int(ranked.score * 100))")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(width: 34, alignment: .trailing)
                }
                .padding(12)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var importedProfileRows: some View {
        VStack(spacing: 10) {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.configProfiles) { profile in
                        HStack(spacing: 10) {
                            Button {
                                model.selectConfigProfile(id: profile.id)
                            } label: {
                                HStack(spacing: 12) {
                                    profileSummary(profile)
                                }
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Text(profile.kind.rawValue)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.teal)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(minWidth: 108)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.teal.opacity(0.14), in: Capsule())

                            profileActionButton(symbol: "pencil") {
                                renamingProfile = profile
                            }
                            .accessibilityLabel("Rename \(profile.displayName)")

                            profileActionButton(symbol: "trash") {
                                deletingProfile = profile
                            }
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Delete \(profile.displayName)")
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(profile.id == model.displayedConfigProfile?.id ? 0.11 : 0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                model.reconnectConfigProfile(id: profile.id)
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.trailing, 4)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .scrollIndicators(.visible)

            if let actionMessage {
                Text(actionMessage)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(actionMessage.localizedCaseInsensitiveContains("could not") || actionMessage.localizedCaseInsensitiveContains("cannot") ? .orange : .mint)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(minHeight: 0, maxHeight: 310)
    }

    private var profileImportMenu: some View {
        Menu {
            Button {
                showPasteImport = true
            } label: {
                Label("Paste key / URL", systemImage: "doc.on.clipboard")
            }

            Button {
                showConfImporter = true
            } label: {
                Label("Import .conf", systemImage: "doc.badge.plus")
            }

            Button {
                showJSONImporter = true
            } label: {
                Label("Import JSON", systemImage: "curlybraces.square")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .bold))
                .frame(width: 34, height: 28)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .accessibilityLabel("Add profile")
    }

    private func profileSummary(_ profile: StoredAmneziaConfigProfile) -> some View {
        Group {
            Image(systemName: profile.id == model.displayedConfigProfile?.id ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(profile.id == model.displayedConfigProfile?.id ? .teal : .white.opacity(0.38))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(profileDetail(profile))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            .layoutPriority(1)
        }
    }

    private func profileActionButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.82))
    }

    private func importFileResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                return
            }
            do {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let imported = try String(contentsOf: url, encoding: .utf8)
                Task {
                    if let error = await model.importAmneziaConfigProfile(name: url.lastPathComponent, rawConfig: imported) {
                        actionMessage = error
                    } else {
                        actionMessage = "Imported \(url.lastPathComponent) as active profile."
                    }
                }
            } catch {
                actionMessage = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        case .failure(let error):
            actionMessage = "Could not import config: \(error.localizedDescription)"
        }
    }

    private func profileDetail(_ profile: StoredAmneziaConfigProfile) -> String {
        var parts: [String] = []
        if let regionCode = profile.regionCode {
            parts.append(regionCode)
        }
        if let endpointHost = profile.endpointHost {
            parts.append(endpointHost)
        }
        if profile.id == model.connectedConfigProfile?.id {
            parts.append("connected")
        } else {
            parts.append(profile.id == model.activeConfigProfile?.id ? "active" : "standby")
        }
        return parts.joined(separator: " · ")
    }
}

struct ProfilePasteImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var rawConfig = ""
    let onImport: (String, String) -> Void

    private var trimmedConfig: String {
        rawConfig.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Profile")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                Text("Paste a vpn:// key, VLESS URL, subscription URL, or raw config.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Display name")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                TextField("Optional name", text: $displayName)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Key / URL / Config")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                TextEditor(text: $rawConfig)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(minHeight: 180)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Import") {
                    onImport(displayName, rawConfig)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedConfig.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560, height: 430)
        .background(
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.14, blue: 0.18), Color(red: 0.10, green: 0.09, blue: 0.15)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

struct ProfileRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let profile: StoredAmneziaConfigProfile
    let onSave: (String) -> Void
    @State private var displayName: String

    init(profile: StoredAmneziaConfigProfile, onSave: @escaping (String) -> Void) {
        self.profile = profile
        self.onSave = onSave
        _displayName = State(initialValue: profile.displayName)
    }

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rename Profile")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                Text(profile.endpointHost ?? profile.kind.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }

            TextField("Profile name", text: $displayName)
                .textFieldStyle(.plain)
                .padding(10)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(.white)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    onSave(displayName)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420, height: 220)
        .background(
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.14, blue: 0.18), Color(red: 0.10, green: 0.09, blue: 0.15)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

struct RecoveryPanel: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        Panel(title: model.vpnStatus.isConnectedOrConnecting ? "Recovery" : "Recovery Plan", symbol: "arrow.triangle.2.circlepath") {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: actionSymbol)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(actionTint)
                    .frame(height: 44)

                Text(actionTitle)
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                Text(actionReason)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(2)

                Text(model.probeReliabilityDetail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(2)

                if let lastProbeDate = model.lastProbeDate {
                    Text("Last probe \(lastProbeDate.formatted(date: .omitted, time: .standard)) · \(model.monitorStatus)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(2)
                } else {
                    Text(model.monitorStatus)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Button {
                    model.applyRecoveryAction()
                } label: {
                    Label(model.vpnStatus.isConnectedOrConnecting ? "Apply" : "Apply Plan", systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
            }
        }
    }

    private var actionTitle: String {
        switch model.healthAssessment.recommendedAction {
        case .keepCurrent:
            return model.vpnStatus.isConnectedOrConnecting ? "Keep \(model.activeProfileDisplayName)" : "Ready to Connect"
        case .refreshDirectDNS:
            return "Refresh DNS"
        case .reconnect:
            return "Reconnect \(model.activeProfileDisplayName)"
        case .switchServer(_, let to, _):
            return "Switch to \(model.displayName(forServerID: to))"
        case .adjustParameters:
            return "Tune Tunnel"
        case .askUser:
            return "Check Network"
        }
    }

    private var actionReason: String {
        switch model.healthAssessment.recommendedAction {
        case .keepCurrent(let reason), .refreshDirectDNS(let reason), .reconnect(_, let reason),
             .switchServer(_, _, let reason), .adjustParameters(_, _, let reason), .askUser(let reason):
            return friendlyReason(reason)
        }
    }

    private func friendlyReason(_ reason: String) -> String {
        switch reason {
        case "vpn-path-healthy":
            return "Current tunnel probes are healthy."
        case "provider-path-down":
            return "Local provider path is not responding."
        case "provider-dns-or-direct-path-degraded":
            return "Local provider or DNS probes are degraded."
        case "vpn-path-degraded":
            return "Tunnel probes are degraded; refresh/rehandshake is recommended."
        default:
            return reason.replacingOccurrences(of: "-", with: " ")
        }
    }

    private var actionSymbol: String {
        switch model.healthAssessment.recommendedAction {
        case .keepCurrent:
            return "checkmark.shield.fill"
        case .refreshDirectDNS:
            return "network"
        case .reconnect:
            return "arrow.clockwise.circle.fill"
        case .switchServer:
            return "arrow.left.arrow.right.circle.fill"
        case .adjustParameters:
            return "slider.horizontal.3"
        case .askUser:
            return "exclamationmark.triangle.fill"
        }
    }

    private var actionTint: Color {
        switch model.healthAssessment.recommendedAction {
        case .keepCurrent:
            return .mint
        case .refreshDirectDNS, .adjustParameters:
            return .yellow
        case .reconnect, .switchServer:
            return .orange
        case .askUser:
            return .red
        }
    }
}

struct Panel<Content: View, Accessory: View>: View {
    var title: String
    var symbol: String
    var accessory: Accessory
    var content: Content

    init(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) where Accessory == EmptyView {
        self.title = title
        self.symbol = symbol
        accessory = EmptyView()
        self.content = content()
    }

    init(
        title: String,
        symbol: String,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(.teal)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                accessory
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(18)
        .frame(minHeight: 210)
        .background(.ultraThinMaterial.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }
}

struct SettingsView: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appVisibilityMode") private var appVisibilityModeRaw = AppVisibilityMode.dockAndMenuBar.rawValue
    @State private var amneziaKey = ""
    @State private var message: String?
    @State private var selectedTab: SettingsTab = .connection
    @State private var showConfigImporter = false
    @State private var forceVPNException = ""
    @State private var bypassVPNException = ""

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.10, blue: 0.13),
                    Color(red: 0.12, green: 0.16, blue: 0.20),
                    Color(red: 0.11, green: 0.10, blue: 0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Settings")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Connection keys and local routing preferences")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.68))
                    }

                    Spacer()

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.62))
                }

                Picker("", selection: $selectedTab) {
                    Text("Connection").tag(SettingsTab.connection)
                    Text("App").tag(SettingsTab.app)
                    Text("Routing").tag(SettingsTab.routing)
                    Text("Regions").tag(SettingsTab.regions)
                    Text("Signing").tag(SettingsTab.signing)
                }
                .pickerStyle(.segmented)
                .colorScheme(.dark)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch selectedTab {
                        case .connection:
                            connectionSettings
                        case .app:
                            appSettings
                        case .routing:
                            routingSettings
                        case .regions:
                            regionSettings
                        case .signing:
                            signingSettings
                        }
                    }
                    .padding(.trailing, 4)
                }

                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(message.hasPrefix("Saved") || message.hasPrefix("Imported") || message.hasPrefix("Deleted") ? .mint : .orange)
                        .lineLimit(2)
                }

                HStack {
                    Button("Save") {
                        if let error = model.saveAmneziaPremiumKey(amneziaKey) {
                            message = error
                        } else {
                            message = "Saved Amnezia config in Keychain."
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)

                    Button("Import .conf") {
                        showConfigImporter = true
                    }
                    .buttonStyle(.bordered)
                    .tint(.white.opacity(0.82))

                    Button("Delete Active", role: .destructive) {
                        if let error = model.deleteActiveConfigProfile() {
                            message = error
                        } else {
                            amneziaKey = ""
                            message = "Deleted active Amnezia config."
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)

                    Spacer()

                    Button("Close") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .tint(.white.opacity(0.82))
                }
            }
            .padding(28)
        }
        .frame(width: 620, height: 620)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        )
        .onAppear {
            amneziaKey = model.loadAmneziaPremiumKeyForEditing()
        }
        .fileImporter(
            isPresented: $showConfigImporter,
            allowedContentTypes: [
                .plainText,
                .json,
                .url,
                .data,
                UTType(filenameExtension: "conf") ?? .data
            ],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    return
                }
                do {
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if didAccess {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    let imported = try String(contentsOf: url, encoding: .utf8)
                    Task {
                        if let error = await model.importAmneziaConfigProfile(name: url.lastPathComponent, rawConfig: imported) {
                            message = error
                        } else {
                            amneziaKey = model.loadAmneziaPremiumKeyForEditing()
                            message = "Imported \(url.lastPathComponent) as the active profile."
                        }
                    }
                } catch {
                    message = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
                }
            case .failure(let error):
                message = "Could not import config: \(error.localizedDescription)"
            }
        }
    }

    private var connectionSettings: some View {
        SettingsCard(title: "Amnezia Profiles") {
            VStack(alignment: .leading, spacing: 12) {
                if model.configProfiles.isEmpty {
                    Text("No imported profiles yet.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.66))
                } else {
                    Picker("Active profile", selection: Binding(
                        get: { model.activeConfigProfileID ?? "" },
                        set: { model.selectConfigProfile(id: $0.isEmpty ? nil : $0) }
                    )) {
                        ForEach(model.configProfiles) { profile in
                            Text(profileRowTitle(profile)).tag(profile.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .colorScheme(.dark)
                }

                SecureField("Paste Amnezia Premium key, vpn:// link, or import an AWG .conf", text: $amneziaKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.white.opacity(0.18), lineWidth: 1)
                    )

                HStack(spacing: 8) {
                    Image(systemName: model.hasAmneziaPremiumKey ? "checkmark.seal.fill" : "key")
                        .foregroundStyle(model.hasAmneziaPremiumKey ? .mint : .white.opacity(0.58))
                    Text(model.hasAmneziaPremiumKey ? "\(model.activeConfigSummary) is stored in macOS Keychain." : "No Amnezia config is stored yet.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.72))
                }

                Text("Imported .conf profiles are mutually exclusive with the raw Premium token for Connect: the selected ready-to-use AWG profile is used. Secrets stay in Keychain and are not written to logs, UserDefaults, or test fixtures.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.58))
            }
        }
    }

    private var appSettings: some View {
        SettingsCard(title: "App Display") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Show Real Ai VPN", selection: Binding(
                    get: { appVisibilityMode },
                    set: { appVisibilityModeRaw = $0.rawValue }
                )) {
                    ForEach(AppVisibilityMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(appVisibilityMode.detail)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.62))

                Divider()
                    .overlay(.white.opacity(0.16))

                Toggle("Auto-switch profile and show popup", isOn: $model.automaticFailoverEnabled)
                    .toggleStyle(.switch)

                Text("When the active VPN path stalls, Real Ai VPN switches to the best imported profile, reconnects, and shows a confirmation popup.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.58))

                Toggle("Kill Switch", isOn: $model.killSwitchEnabled)
                    .toggleStyle(.switch)

                Text("When enabled, protected traffic is kept inside the VPN while local, private, RU, and explicit “Without VPN” routes remain direct.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.58))

                Divider()
                    .overlay(.white.opacity(0.16))

                HStack(alignment: .top, spacing: 10) {
                    ActiveMenuBarShieldIcon()
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Connected menu bar icon")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.82))
                        Text("When VPN is connected, the shield becomes filled and the A is cut out as transparent space.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.58))
                    }
                }
            }
        }
    }

    private var routingSettings: some View {
        SettingsCard(title: "Current Region Exceptions") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Rules accept exact domains, IPs, or CIDR ranges. Changes are applied on the next reconnect so the current tunnel is not disturbed.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.62))

                exceptionInput(
                    title: "Через VPN",
                    placeholder: "example.ru or 203.0.113.10",
                    text: $forceVPNException,
                    mode: .forceVPN
                )

                exceptionInput(
                    title: "Без VPN",
                    placeholder: "mos.ru or 203.0.113.0/24",
                    text: $bypassVPNException,
                    mode: .bypassVPN
                )

                Divider()
                    .overlay(.white.opacity(0.16))

                if model.routingExceptions.rules.isEmpty {
                    Text("No routing exceptions yet.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.62))
                } else {
                    ForEach(model.routingExceptions.rules) { rule in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { rule.isEnabled },
                                set: { model.setRoutingExceptionEnabled(id: rule.id, isEnabled: $0) }
                            ))
                            .labelsHidden()

                            VStack(alignment: .leading, spacing: 3) {
                                Text(rule.value)
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                Text(rule.mode.title)
                                    .font(.caption)
                                    .foregroundStyle(rule.mode == .forceVPN ? .cyan : .mint)
                            }

                            Spacer()

                            Button(role: .destructive) {
                                model.deleteRoutingException(id: rule.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.orange)
                        }
                        .padding(10)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
    }

    private func exceptionInput(
        title: String,
        placeholder: String,
        text: Binding<String>,
        mode: RoutingExceptionMode
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.callout.weight(.semibold))
                .frame(width: 82, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                )
            Button {
                model.addRoutingException(value: text.wrappedValue, mode: mode)
                text.wrappedValue = ""
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(mode == .forceVPN ? .cyan : .mint)
            .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var appVisibilityMode: AppVisibilityMode {
        AppVisibilityMode(rawValue: appVisibilityModeRaw) ?? .dockAndMenuBar
    }

    private func profileRowTitle(_ profile: StoredAmneziaConfigProfile) -> String {
        var parts = [profile.displayName]
        if let regionCode = profile.regionCode {
            parts.append(regionCode)
        }
        if let endpointHost = profile.endpointHost {
            parts.append(endpointHost)
        }
        return parts.joined(separator: " · ")
    }

    private var regionSettings: some View {
        SettingsCard(title: "Regional Defaults") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Current region")
                    Spacer()
                    Text(model.currentRegion.rawValue)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.68))
                }

                HStack {
                    Text("Home region")
                    Spacer()
                    Text(model.homeRegion.rawValue)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.68))
                }

                Text("Region editing will move here when we replace demo state with persistent profiles.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.58))
            }
        }
    }

    private var signingSettings: some View {
        SettingsCard(title: "Developer Signing") {
            VStack(alignment: .leading, spacing: 10) {
                Label("Team ID: 9FP39GTDT5", systemImage: "person.badge.key.fill")
                Label("Bundle ID: com.codex.RealAiVPN", systemImage: "shippingbox.fill")
                Label("Entitlements: Network Extension packet tunnel", systemImage: "lock.shield.fill")

                Text("Use scripts/build_and_install_app.sh for the TeleFeed-style signed install flow.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.58))
            }
            .font(.callout)
        }
    }
}

private enum SettingsTab: Hashable {
    case connection
    case app
    case routing
    case regions
    case signing
}

struct SettingsCard<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
    }
}

struct HealthRow: View {
    var title: String
    var report: PathHealthReport
    var tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(stateColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(report.reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.54))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                Text(report.state.rawValue.capitalized)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                Text("\(Int(report.successRate * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.54))
                    .lineLimit(1)
            }
            .frame(width: 78, alignment: .trailing)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .center)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var stateColor: Color {
        switch report.state {
        case .healthy:
            return .mint
        case .degradedSoft, .degradedHard:
            return .yellow
        case .stalled, .connectedButUnusable:
            return .orange
        case .down:
            return .red
        }
    }
}

struct StatusRow: View {
    var title: String
    var detail: String
    var state: String
    var value: String
    var color: Color

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.54))
                    .lineLimit(1)
            }
            .layoutPriority(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                Text(state)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.54))
                    .lineLimit(1)
            }
            .frame(width: 78, alignment: .trailing)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .center)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct CapsuleLabel: View {
    var text: String
    var symbol: String
    var tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }
}

private extension ServerQualitySample {
    static func sample(
        serverID: String,
        region: RegionCode,
        latency: Double,
        handshake: Double,
        loss: Double,
        failures: Int = 0
    ) -> ServerQualitySample {
        ServerQualitySample(
            serverID: serverID,
            region: region,
            networkKind: .wifi,
            providerASNHash: "hashed-provider",
            latencyMilliseconds: latency,
            packetLoss: loss,
            handshakeMilliseconds: handshake,
            recentFailureCount: failures
        )
    }
}

private extension Array where Element == ConnectivityProbeResult {
    static let healthyDirect: [ConnectivityProbeResult] = [
        .probe(targetID: "provider-dns", targetKind: .dnsResolver, method: .dnsQuery, succeeded: true, latency: 22),
        .probe(targetID: "ru-local", targetKind: .directEndpoint, method: .httpHead, succeeded: true, latency: 38),
        .probe(targetID: "provider-dns", targetKind: .dnsResolver, method: .dnsQuery, succeeded: true, latency: 24)
    ]

    static func healthyVPN(serverID: String) -> [ConnectivityProbeResult] {
        [
            .probe(targetID: "handshake", targetKind: .vpnServer, serverID: serverID, method: .tunnelHandshake, succeeded: true, latency: 122),
            .probe(targetID: "vpn-dns", targetKind: .vpnProtectedEndpoint, serverID: serverID, method: .dnsQuery, succeeded: true, latency: 142),
            .probe(targetID: "foreign", targetKind: .vpnProtectedEndpoint, serverID: serverID, method: .httpHead, succeeded: true, latency: 166)
        ]
    }

    static func degradedVPN(serverID: String) -> [ConnectivityProbeResult] {
        [
            .probe(targetID: "handshake", targetKind: .vpnServer, serverID: serverID, method: .tunnelHandshake, succeeded: true, latency: 1_280, loss: 0.1),
            .probe(targetID: "vpn-dns", targetKind: .vpnProtectedEndpoint, serverID: serverID, method: .dnsQuery, succeeded: true, latency: 1_360, loss: 0.12),
            .probe(targetID: "foreign", targetKind: .vpnProtectedEndpoint, serverID: serverID, method: .httpHead, succeeded: true, latency: 1_460, loss: 0.1)
        ]
    }

    static func downVPN(serverID: String) -> [ConnectivityProbeResult] {
        [
            .probe(targetID: "handshake", targetKind: .vpnServer, serverID: serverID, method: .tunnelHandshake, succeeded: false),
            .probe(targetID: "vpn-dns", targetKind: .vpnProtectedEndpoint, serverID: serverID, method: .dnsQuery, succeeded: false),
            .probe(targetID: "foreign", targetKind: .vpnProtectedEndpoint, serverID: serverID, method: .httpHead, succeeded: false)
        ]
    }
}

private extension ConnectivityProbeResult {
    static func probe(
        targetID: String,
        targetKind: ProbeTargetKind,
        serverID: String? = nil,
        method: ProbeMethod,
        succeeded: Bool,
        latency: Double? = nil,
        loss: Double = 0
    ) -> ConnectivityProbeResult {
        ConnectivityProbeResult(
            targetID: targetID,
            targetKind: targetKind,
            serverID: serverID,
            method: method,
            succeeded: succeeded,
            latencyMilliseconds: latency,
            packetLoss: loss
        )
    }
}
