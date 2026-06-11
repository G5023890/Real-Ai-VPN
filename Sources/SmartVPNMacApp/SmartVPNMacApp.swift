import AmneziaConfig
import AppKit
import Combine
import Network
import RealVPNCore
import ServiceManagement
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
        Window("Real Ai Router", id: "main") {
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
                .accessibilityLabel("Real Ai Router connected")
        } else {
            Image(systemName: "shield.fill")
                .resizable()
                .scaledToFit()
                .accessibilityLabel("Real Ai Router connected")
        }
    }
}

struct StoredProfileQualityHistory: Codable {
    var samples: [ServerQualitySample]
}

struct StoredProbeReliabilityHistory: Codable {
    var probes: [ConnectivityProbeResult]
}

struct VPNChannelStatistics: Identifiable {
    var id: String
    var displayName: String
    var regionCode: String
    var protocolKind: VPNProtocolKind
    var sampleCount: Int
    var averageLatencyMilliseconds: Double?
    var averagePacketLoss: Double
    var averageHandshakeMilliseconds: Double?
    var successRate: Double
    var failureCount: Int
    var lastSeen: Date?
    var reliabilitySummary: ProbeReliabilitySummary?
    var ranking: RankedServer?
    var isActive: Bool
    var isConnected: Bool
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
    @Published var connectOnStartEnabled = UserDefaults.standard.object(forKey: "connectOnStartEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(connectOnStartEnabled, forKey: "connectOnStartEnabled")
            Task { await vpnManager.prepareProfile(configuration: vpnConfiguration) }
        }
    }
    @Published var reconnectAfterDropEnabled = UserDefaults.standard.object(forKey: "reconnectAfterDropEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(reconnectAfterDropEnabled, forKey: "reconnectAfterDropEnabled")
            Task { await vpnManager.prepareProfile(configuration: vpnConfiguration) }
        }
    }
    @Published var killSwitchEnabled = UserDefaults.standard.object(forKey: "killSwitchEnabled") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(killSwitchEnabled, forKey: "killSwitchEnabled")
        }
    }
    @Published var dnsProtectionEnabled = UserDefaults.standard.object(forKey: "dnsProtectionEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(dnsProtectionEnabled, forKey: "dnsProtectionEnabled")
        }
    }
    @Published var showFailoverNotifications = UserDefaults.standard.object(forKey: "showFailoverNotifications") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showFailoverNotifications, forKey: "showFailoverNotifications")
        }
    }
    @Published var localNetworkAccessEnabled = UserDefaults.standard.object(forKey: "localNetworkAccessEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(localNetworkAccessEnabled, forKey: "localNetworkAccessEnabled")
        }
    }
    @Published var ipv6LeakProtectionEnabled = UserDefaults.standard.object(forKey: "ipv6LeakProtectionEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(ipv6LeakProtectionEnabled, forKey: "ipv6LeakProtectionEnabled")
        }
    }
    @Published var launchAtLoginEnabled = UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(launchAtLoginEnabled, forKey: "launchAtLogin")
            configureLaunchAtLogin(launchAtLoginEnabled)
        }
    }
    @Published var preferredLanguage = UserDefaults.standard.string(forKey: "preferredLanguage") ?? "English" {
        didSet {
            UserDefaults.standard.set(preferredLanguage, forKey: "preferredLanguage")
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
    private var dropRecoveryTask: Task<Void, Never>?
    private var dropRecoveryProfileID: String?
    private var dropRecoveryAttempt = 0
    private let maxDropReconnectAttempts = 5
    private let dropReconnectDelaySeconds: UInt64 = 2

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
        configureLaunchAtLogin(launchAtLoginEnabled)
        Task {
            await vpnManager.prepareProfile(configuration: vpnConfiguration)
            await connectOnStartIfNeeded()
        }
    }

    deinit {
        monitoringTask?.cancel()
        dropRecoveryTask?.cancel()
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

    var channelStatistics: [VPNChannelStatistics] {
        effectiveServers.map { server in
            let samples = qualitySamples
                .filter { $0.serverID == server.id }
                .sorted { $0.timestamp < $1.timestamp }
            let recentSamples = Array(samples.suffix(60))
            let successSamples = recentSamples.filter { $0.packetLoss < 1 }
            let reliability = probeReliabilityAnalyzer.bestSummary(
                from: probeReliabilitySamples,
                serverID: server.id,
                targetKind: .vpnProtectedEndpoint
            )
            let ranking = rankedServers.first { $0.server.id == server.id }
                ?? routeDecision.rankedServers.first { $0.server.id == server.id }
            let activeID = displayedConfigProfile?.id ?? activeConfigProfile?.id ?? activeServerID
            let connectedID = connectedConfigProfile?.id

            return VPNChannelStatistics(
                id: server.id,
                displayName: server.displayName,
                regionCode: server.region.rawValue,
                protocolKind: server.protocolKind,
                sampleCount: recentSamples.count,
                averageLatencyMilliseconds: average(recentSamples.map(\.latencyMilliseconds)),
                averagePacketLoss: average(recentSamples.map(\.packetLoss)) ?? 0,
                averageHandshakeMilliseconds: average(recentSamples.map(\.handshakeMilliseconds)),
                successRate: recentSamples.isEmpty ? 0 : Double(successSamples.count) / Double(recentSamples.count),
                failureCount: recentSamples.reduce(0) { $0 + $1.recentFailureCount },
                lastSeen: recentSamples.last?.timestamp ?? reliability?.lastSeen,
                reliabilitySummary: reliability,
                ranking: ranking,
                isActive: server.id == activeID,
                isConnected: vpnStatus.isConnectedOrConnecting && server.id == connectedID
            )
        }
        .sorted { lhs, rhs in
            if lhs.isConnected != rhs.isConnected {
                return lhs.isConnected
            }
            if lhs.isActive != rhs.isActive {
                return lhs.isActive
            }
            return (lhs.ranking?.score ?? lhs.successRate) > (rhs.ranking?.score ?? rhs.successRate)
        }
    }

    var dnsPolicyDiagnostic: String {
        guard dnsProtectionEnabled else {
            return "Profile DNS only"
        }

        guard displayedConfigProfile?.kind == .singBoxVLESSReality else {
            return "Profile DNS only · split-dns-provider-lane unavailable for AWG"
        }

        return "Provider DNS lane: Yandex DNS"
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
                reconnectVPN(reason: "Switching VPN profile")
            }
        case .reconnect(let serverID, _), .adjustParameters(let serverID, _, _):
            switchToProfileOrServer(id: serverID)
            if wasConnected {
                reconnectVPN(reason: "Reconnecting VPN profile")
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
        cancelDropRecovery()
        activeConfigProfileID = id
    }

    func reconnectConfigProfile(id: String) {
        cancelDropRecovery()
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
                await waitUntilVPNIsDisconnected()
                connectVPN()
            }
        } else {
            connectVPN()
        }
    }

    func connectVPN() {
        if dropRecoveryTask == nil {
            cancelDropRecovery()
        }
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
        cancelDropRecovery()
        guard vpnStatus.isConnectedOrConnecting else {
            return
        }

        suppressExpectedDisconnectNotification = true
        vpnStatus = .disconnecting
        Task {
            await vpnManager.disconnectDisablingOnDemand()
        }
    }

    func reconnectVPN(reason: String = "Reconnecting VPN") {
        cancelDropRecovery()
        guard vpnStatus.isConnectedOrConnecting else {
            connectVPN()
            return
        }

        vpnStatus = .disconnecting
        suppressExpectedDisconnectNotification = true
        monitorStatus = killSwitchEnabled ? "\(reason) with Kill Switch" : reason
        vpnManager.disconnect()
        Task {
            await waitUntilVPNIsDisconnected()
            connectVPN()
        }
    }

    func reconnectVPNWithKillSwitch() {
        killSwitchEnabled = true
        monitorStatus = vpnStatus.isConnectedOrConnecting
            ? "Reconnecting with Kill Switch"
            : "Connecting with Kill Switch"
        reconnectVPN(reason: "Reconnecting")
    }

    func toggleVPN() {
        if vpnStatus.isConnectedOrConnecting {
            disconnectVPN()
        } else {
            connectVPN()
        }
    }

    private func connectOnStartIfNeeded() async {
        guard connectOnStartEnabled else {
            return
        }

        try? await Task.sleep(for: .seconds(1))
        guard !vpnStatus.isConnectedOrConnecting, activeConfigProfile != nil else {
            return
        }

        monitorStatus = "Connecting VPN on app start"
        connectVPN()
    }

    private func cancelDropRecovery() {
        dropRecoveryTask?.cancel()
        clearDropRecoveryState()
    }

    private func clearDropRecoveryState() {
        dropRecoveryTask = nil
        dropRecoveryProfileID = nil
        dropRecoveryAttempt = 0
    }

    private func reconnectAfterUnexpectedDrop(profileID: String?, profileName: String) {
        guard reconnectAfterDropEnabled,
              dropRecoveryTask == nil,
              let profileID,
              configProfiles.contains(where: { $0.id == profileID }) else {
            return
        }

        dropRecoveryProfileID = profileID
        dropRecoveryTask = Task { @MainActor [weak self] in
            await self?.runDropRecovery(profileID: profileID, profileName: profileName)
        }
    }

    private func runDropRecovery(profileID: String, profileName: String) async {
        defer {
            clearDropRecoveryState()
        }

        for attempt in 1...maxDropReconnectAttempts {
            if Task.isCancelled {
                return
            }

            guard configProfiles.contains(where: { $0.id == profileID }) else {
                monitorStatus = "Last VPN failed after 5 attempts. No healthy fallback profile."
                return
            }

            dropRecoveryAttempt = attempt
            activeConfigProfileID = profileID
            monitorStatus = "Reconnecting \(profileName) after drop/reset (\(attempt)/\(maxDropReconnectAttempts))..."
            vpnErrorMessage = nil
            connectVPN()

            if await waitForDropRecoveryConnection(profileID: profileID) {
                monitorStatus = "Connected to \(profileName)."
                return
            }

            if attempt < maxDropReconnectAttempts {
                try? await Task.sleep(for: .seconds(dropReconnectDelaySeconds))
            }
        }

        await applyDropRecoveryFailover(failedProfileID: profileID, failedProfileName: profileName)
    }

    private func waitForDropRecoveryConnection(profileID: String, timeoutSeconds: Double = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        repeat {
            if Task.isCancelled {
                return false
            }
            if (vpnStatus == .connected || vpnStatus == .reasserting),
               connectedConfigProfileID == profileID {
                return true
            }
            try? await Task.sleep(for: .milliseconds(300))
        } while Date() < deadline

        return false
    }

    private func waitUntilVPNIsDisconnected(timeoutSeconds: Double = 3) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if vpnStatus == .disconnected || vpnStatus == .invalid || vpnStatus == .unknown {
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private func applyDropRecoveryFailover(failedProfileID: String, failedProfileName: String) async {
        guard automaticFailoverEnabled else {
            monitorStatus = "Last VPN failed after 5 attempts. Auto-switch is disabled."
            return
        }

        quarantineProfile(id: failedProfileID)
        monitorStatus = "Switching after failed reconnect attempts..."
        refresh()

        let recommendedID: String?
        if case .switchServer(_, let to, _) = healthAssessment.recommendedAction,
           to != failedProfileID,
           configProfiles.contains(where: { $0.id == to }) {
            recommendedID = to
        } else {
            recommendedID = rankedServers
                .map(\.server.id)
                .first { id in
                    id != failedProfileID && configProfiles.contains(where: { $0.id == id })
                }
        }

        guard let recommendedID else {
            monitorStatus = "Last VPN failed after 5 attempts. No healthy fallback profile."
            return
        }

        let oldProfile = failedProfileName
        switchToProfileOrServer(id: recommendedID)
        lastAutomaticFailoverDate = Date()
        notifyFailover(from: oldProfile, to: activeConfigSummary, reason: "drop-reset-retry-exhausted")
        connectVPN()
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
        let droppedProfileID = connectedConfigProfileID ?? displayedConfigProfile?.id ?? activeConfigProfile?.id
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
            reconnectAfterUnexpectedDrop(profileID: droppedProfileID, profileName: droppedProfile)
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
            killSwitchEnabled: killSwitchEnabled,
            dnsProtectionEnabled: dnsProtectionEnabled,
            localNetworkAccessEnabled: localNetworkAccessEnabled,
            ipv6LeakProtectionEnabled: ipv6LeakProtectionEnabled,
            autoReconnectOnDemandEnabled: reconnectAfterDropEnabled
        )
    }

    private func localizedVPNDescription(for profile: StoredAmneziaConfigProfile?) -> String {
        profile?.kind == .singBoxVLESSReality ? "Real Ai Router VLESS" : "Real Ai Router AWG"
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

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }

        return values.reduce(0, +) / Double(values.count)
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
        vpnStatus = .disconnecting
        monitorStatus = killSwitchEnabled ? "Switching VPN with Kill Switch" : "Switching VPN"
        vpnManager.disconnect()
        await waitUntilVPNIsDisconnected()
        connectVPN()
    }

    private func notifyTunnelDropped(profile: String) {
        let content = UNMutableNotificationContent()
        content.title = "Real Ai Router disconnected"
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
        guard showFailoverNotifications else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Real Ai Router switched profile"
        content.body = "\(oldProfile) → \(newProfile). \(reason)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "real-ai-vpn-macos-failover-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func configureLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            UserDefaults.standard.set(false, forKey: "launchAtLogin")
            if launchAtLoginEnabled {
                launchAtLoginEnabled = false
            }
            vpnErrorMessage = "Could not update Launch at Login: \(error.localizedDescription)"
        }
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

private enum MacSidebarPage: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case profiles = "VPN Profiles"
    case routing = "Routing"
    case settings = "Settings"
    case statistics = "Stat"
    case about = "About"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .dashboard:
            return "house"
        case .profiles:
            return "server.rack"
        case .routing:
            return "arrow.triangle.branch"
        case .settings:
            return "gearshape"
        case .statistics:
            return "chart.line.uptrend.xyaxis"
        case .about:
            return "info.circle"
        }
    }
}

private enum MacSettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case regions = "Regions"
    case security = "Security"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general:
            return "sparkles"
        case .regions:
            return "globe"
        case .security:
            return "shield.checkered"
        }
    }
}

private struct MacLiquidTheme {
    let scheme: ColorScheme

    var background: LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.11, blue: 0.15),
                    Color(red: 0.12, green: 0.16, blue: 0.20),
                    Color(red: 0.10, green: 0.09, blue: 0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        return LinearGradient(
            colors: [
                Color(red: 0.96, green: 0.98, blue: 0.99),
                Color(red: 0.99, green: 0.995, blue: 1.0),
                Color(red: 0.93, green: 0.96, blue: 0.98)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var primaryText: Color {
        scheme == .dark ? .white : Color(red: 0.06, green: 0.08, blue: 0.10)
    }

    var secondaryText: Color {
        scheme == .dark ? .white.opacity(0.64) : Color(red: 0.34, green: 0.39, blue: 0.45)
    }

    var tertiaryText: Color {
        scheme == .dark ? .white.opacity(0.44) : Color(red: 0.52, green: 0.57, blue: 0.63)
    }

    var cardFill: Color {
        scheme == .dark ? .white.opacity(0.08) : .white.opacity(0.72)
    }

    var rowFill: Color {
        scheme == .dark ? .white.opacity(0.075) : Color(red: 0.96, green: 0.98, blue: 0.99).opacity(0.86)
    }

    var selectedFill: Color {
        Color.teal.opacity(scheme == .dark ? 0.22 : 0.12)
    }

    var stroke: Color {
        scheme == .dark ? .white.opacity(0.14) : Color.black.opacity(0.08)
    }

    var accent: Color { .teal }
    var success: Color { .mint }
    var warning: Color { .orange }
    var danger: Color { .red }
}

private extension View {
    func macLiquidCard(_ theme: MacLiquidTheme, radius: CGFloat = 14) -> some View {
        self
            .background(.ultraThinMaterial.opacity(theme.scheme == .dark ? 0.74 : 0.88), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(theme.cardFill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(theme.stroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(theme.scheme == .dark ? 0.18 : 0.06), radius: 18, x: 0, y: 10)
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @Binding var showSettings: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedPage: MacSidebarPage = .dashboard
    @State private var selectedSettingsSection: MacSettingsSection = .general

    private var buildLabel: String {
        Bundle.main.object(forInfoDictionaryKey: "RAIVPNBuildLabel") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "dev"
    }

    var body: some View {
        let theme = MacLiquidTheme(scheme: colorScheme)

        GeometryReader { proxy in
            let compactSidebar = proxy.size.width < 920

            HStack(spacing: 0) {
                sidebar(theme: theme, compact: compactSidebar)
                    .frame(width: compactSidebar ? 74 : 188)

                Divider()
                    .opacity(colorScheme == .dark ? 0.35 : 0.55)

                VStack(spacing: 0) {
                    topBar(theme: theme, compact: compactSidebar)
                    Divider().opacity(colorScheme == .dark ? 0.2 : 0.55)
                    pageContent(theme: theme, compact: compactSidebar)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(theme.background.ignoresSafeArea())
        .foregroundStyle(theme.primaryText)
        .onAppear {
            openSettingsPageIfRequested()
        }
        .onChange(of: showSettings) { _, _ in
            openSettingsPageIfRequested()
        }
    }

    private func openSettingsPageIfRequested() {
        guard showSettings else {
            return
        }

        selectedPage = .settings
        selectedSettingsSection = .general
        showSettings = false
    }

    private func sidebar(theme: MacLiquidTheme, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if compact {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 46)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Real Ai Router")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                    Text("Smart VPN Routing")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                }
                .padding(.top, 46)
                .padding(.horizontal, 22)
            }

            VStack(spacing: 8) {
                ForEach(MacSidebarPage.allCases.filter { $0 != .about }) { page in
                    sidebarButton(page, theme: theme, compact: compact)
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            VStack(spacing: 8) {
                sidebarButton(.about, theme: theme, compact: compact)
                if !compact {
                    Text("v\(buildLabel)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 18)
        }
        .background(.ultraThinMaterial.opacity(colorScheme == .dark ? 0.34 : 0.62))
    }

    private func sidebarButton(_ page: MacSidebarPage, theme: MacLiquidTheme, compact: Bool) -> some View {
        Button {
            selectedPage = page
        } label: {
            if compact {
                Image(systemName: page.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .foregroundStyle(selectedPage == page ? theme.accent : theme.secondaryText)
                    .background(selectedPage == page ? theme.selectedFill : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Label(page.rawValue, systemImage: page.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .foregroundStyle(selectedPage == page ? theme.accent : theme.secondaryText)
                    .background(selectedPage == page ? theme.selectedFill : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .help(page.rawValue)
    }

    private func topBar(theme: MacLiquidTheme, compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 14) {
            Menu {
                Text(titleSubtitle)
            } label: {
                HStack(spacing: compact ? 6 : 10) {
                    Image(systemName: model.vpnStatus.isConnectedOrConnecting ? "checkmark.shield.fill" : "shield")
                        .foregroundStyle(model.vpnStatus.isConnectedOrConnecting ? .green : theme.secondaryText)
                    Text(model.vpnStatus.rawValue.capitalized)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(theme.primaryText)

            if selectedPage != .settings && !compact {
                Text(selectedPage.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()

            Button {
                selectedPage = .settings
                selectedSettingsSection = .general
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 30)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(theme.secondaryText)

            Button {
                model.toggleVPN()
            } label: {
                Label(connectButtonTitle, systemImage: connectButtonSymbol)
                    .frame(width: compact ? 108 : 132, height: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(model.vpnStatus.isConnectedOrConnecting ? .red : .teal)
        }
        .padding(.horizontal, compact ? 16 : 28)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial.opacity(colorScheme == .dark ? 0.38 : 0.72))
    }

    @ViewBuilder
    private func pageContent(theme: MacLiquidTheme, compact: Bool) -> some View {
        ScrollView {
            switch selectedPage {
            case .dashboard:
                MacDashboardHome(model: model, selectedPage: $selectedPage, theme: theme)
                    .padding(compact ? 14 : 24)
            case .profiles:
                MacProfilesWorkspace(model: model, theme: theme)
                    .padding(compact ? 14 : 24)
            case .routing:
                MacRoutingWorkspace(model: model, theme: theme)
                    .padding(compact ? 14 : 24)
            case .settings:
                MacSettingsWorkspace(
                    model: model,
                    selectedSection: $selectedSettingsSection,
                    theme: theme
                )
                .padding(compact ? 14 : 24)
            case .statistics:
                MacStatisticsWorkspace(model: model, theme: theme)
                    .padding(compact ? 14 : 24)
            case .about:
                MacAboutWorkspace(buildLabel: buildLabel, theme: theme)
                    .padding(compact ? 14 : 24)
            }
        }
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

private struct MacDashboardHome: View {
    @ObservedObject var model: DashboardModel
    @Binding var selectedPage: MacSidebarPage
    let theme: MacLiquidTheme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideLayout
                .frame(minWidth: 980)
            compactLayout
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 16) {
                heroCard
                    .frame(maxWidth: .infinity, minHeight: 260)

                currentRouteCard
                    .frame(maxWidth: .infinity, minHeight: 190)
            }
            .frame(maxWidth: .infinity, alignment: .top)

            VStack(spacing: 16) {
                connectionHealth
                    .frame(maxWidth: .infinity, minHeight: 260)
                profilesPreview
                    .frame(maxWidth: .infinity, minHeight: 190)
            }
            .frame(width: 310, alignment: .top)
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 14) {
            heroCard
                .frame(maxWidth: .infinity, minHeight: 250)
            connectionHealth
                .frame(maxWidth: .infinity)
            currentRouteCard
                .frame(maxWidth: .infinity)
            profilesPreview
                .frame(maxWidth: .infinity)
        }
    }

    private var heroCard: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 26) {
                confidenceMark(size: 190, scale: 2.15, iconSize: 48)
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 24) {
                        heroTextBlock
                            .frame(maxWidth: .infinity, alignment: .leading)
                        heroMetrics
                            .frame(width: 130)
                    }

                    heroButtons
                        .frame(maxWidth: 420, alignment: .leading)
                }
            }

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 18) {
                    confidenceMark(size: 132, scale: 1.55, iconSize: 36)
                    heroTextBlock
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                heroMetrics
                    .frame(maxWidth: .infinity)
                heroButtons
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(26)
        .macLiquidCard(theme)
    }

    private var heroTextBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.vpnStatus.isConnectedOrConnecting ? "Connected" : "Disconnected")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .minimumScaleFactor(0.78)
                .lineLimit(1)

            Text(profileTitle)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(theme.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.78)

            Text("\(Int((model.routeConfidence * 100).rounded()))% confidence")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.teal)
        }
    }

    private var heroButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                switchRouteButton
                connectButton
            }
            .frame(maxWidth: 420)

            VStack(spacing: 10) {
                switchRouteButton
                connectButton
            }
            .frame(maxWidth: 420)
        }
    }

    private var switchRouteButton: some View {
        Button {
            selectedPage = .profiles
        } label: {
            Label("Switch Route", systemImage: "arrow.left.arrow.right")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.teal)
    }

    private var connectButton: some View {
        Button {
            model.toggleVPN()
        } label: {
            Text(model.vpnStatus.isConnectedOrConnecting ? "Disconnect" : "Connect")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.vpnStatus.isConnectedOrConnecting ? .red : .teal)
    }

    private var heroMetrics: some View {
        VStack(alignment: .leading, spacing: 12) {
            metric("Latency", value: latencyText)
            metric("Packet Loss", value: packetLossText)
            metric("Last Check", value: lastCheckText)
        }
    }

    private func confidenceMark(size: CGFloat, scale: CGFloat, iconSize: CGFloat) -> some View {
        ZStack {
            Gauge(value: model.routeConfidence) {
                EmptyView()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(.teal)
            .scaleEffect(scale)

            Image(systemName: model.vpnStatus.isConnectedOrConnecting ? "checkmark.shield.fill" : "shield")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(model.vpnStatus.isConnectedOrConnecting ? .teal : theme.tertiaryText)
        }
        .frame(width: size, height: size)
    }

    private var connectionHealth: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connection Health")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.primaryText)

            MacHealthMiniRow(title: "Provider", report: model.healthAssessment.directPath, theme: theme)
            MacHealthMiniRow(title: "Tunnel", report: model.healthAssessment.vpnPath, theme: theme)
            MacHealthStatusRow(title: "Auto Recovery", value: autoRecoveryStatus, color: autoRecoveryColor, theme: theme)

            Text(model.dnsPolicyDiagnostic)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(2)

            Spacer()

            Label(overallHealthText, systemImage: overallHealthIcon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(overallHealthColor)
        }
        .padding(20)
        .macLiquidCard(theme)
    }

    private var currentRouteCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Current Route")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.primaryText)

            routeLine("Current Region", "\(model.currentRegion.rawValue) - Russia")
            routeLine("Home Region", "\(model.homeRegion.rawValue) - Israel")
            routeLine("Exit Location", exitLocation)

            Divider().opacity(0.45)
            Button {
                selectedPage = .settings
            } label: {
                HStack {
                    Text("Details")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.primaryText)
        }
        .padding(20)
        .macLiquidCard(theme)
    }

    private var profilesPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("VPN Profiles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                Spacer()
                Button {
                    selectedPage = .profiles
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.teal)
            }

            ForEach(Array(model.configProfiles.prefix(3))) { profile in
                HStack(spacing: 10) {
                    Text(profile.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Text(profile.id == model.displayedConfigProfile?.id ? "Active" : "Standby")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(profile.id == model.displayedConfigProfile?.id ? .mint.opacity(0.16) : theme.rowFill, in: Capsule())
                        .foregroundStyle(profile.id == model.displayedConfigProfile?.id ? .mint : theme.secondaryText)
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.teal)
                }
            }

            if model.configProfiles.isEmpty {
                Text("No imported profiles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }

            Divider().opacity(0.45)
            Button {
                selectedPage = .profiles
            } label: {
                HStack {
                    Text("View All Profiles")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.primaryText)
        }
        .padding(20)
        .macLiquidCard(theme)
    }

    private func metric(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.primaryText)
        }
        .lineLimit(1)
    }

    private func routeLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
        }
    }

    private var profileTitle: String {
        guard let profile = model.displayedConfigProfile else {
            return model.activeRouteTitle
        }
        let region = profile.regionCode.map { " · \($0)" } ?? ""
        return "\(profile.displayName)\(region)"
    }

    private var latencyText: String {
        guard let value = model.healthAssessment.vpnPath.averageLatencyMilliseconds else {
            return "n/a"
        }
        guard value > 0 else { return "n/a" }
        return "\(Int(value.rounded())) ms"
    }

    private var packetLossText: String {
        "\(Int((model.healthAssessment.vpnPath.averagePacketLoss * 100).rounded()))%"
    }

    private var lastCheckText: String {
        guard let date = model.lastProbeDate else { return "n/a" }
        let age = max(0, Int(Date().timeIntervalSince(date)))
        return "\(age)s ago"
    }

    private var exitLocation: String {
        if let country = model.observedExitCountry {
            return "\(country) - \(model.observedExitIP ?? "exit hidden")"
        }
        if let profile = model.displayedConfigProfile {
            return "\(profile.regionCode ?? "VPN") - \(profile.displayName)"
        }
        return "Not connected"
    }

    private var recoveryStatus: String {
        switch model.healthAssessment.recommendedAction {
        case .keepCurrent:
            return "Ready"
        case .switchServer:
            return "Switch"
        case .reconnect:
            return "Reconnect"
        case .refreshDirectDNS:
            return "DNS"
        case .adjustParameters:
            return "Tune"
        case .askUser:
            return "Review"
        }
    }

    private var autoRecoveryStatus: String {
        model.automaticFailoverEnabled ? recoveryStatus : "Off"
    }

    private var autoRecoveryColor: Color {
        guard model.automaticFailoverEnabled else {
            return theme.tertiaryText
        }

        switch model.healthAssessment.recommendedAction {
        case .keepCurrent:
            return .mint
        case .refreshDirectDNS:
            return .yellow
        case .switchServer, .reconnect, .adjustParameters, .askUser:
            return .orange
        }
    }

    private var overallHealthText: String {
        guard model.automaticFailoverEnabled else {
            return "Auto recovery disabled"
        }

        let provider = model.healthAssessment.directPath.state
        let tunnel = model.healthAssessment.vpnPath.state
        if provider == .healthy, tunnel == .healthy {
            return "All systems operational"
        }
        if tunnel == .connectedButUnusable || tunnel == .down || tunnel == .stalled {
            return "VPN path needs recovery"
        }
        if provider != .healthy {
            return "Provider path degraded"
        }
        return "Monitoring connection quality"
    }

    private var overallHealthIcon: String {
        guard model.automaticFailoverEnabled else {
            return "pause.circle.fill"
        }

        let provider = model.healthAssessment.directPath.state
        let tunnel = model.healthAssessment.vpnPath.state
        return provider == .healthy && tunnel == .healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var overallHealthColor: Color {
        guard model.automaticFailoverEnabled else {
            return theme.tertiaryText
        }

        let provider = model.healthAssessment.directPath.state
        let tunnel = model.healthAssessment.vpnPath.state
        if provider == .healthy, tunnel == .healthy {
            return .mint
        }
        if tunnel == .degradedSoft || provider == .degradedSoft {
            return .yellow
        }
        return .orange
    }
}

private struct MacHealthMiniRow: View {
    let title: String
    let report: PathHealthReport
    let theme: MacLiquidTheme

    var body: some View {
        MacHealthStatusRow(
            title: title,
            value: report.state.rawValue.capitalized,
            color: color,
            theme: theme,
            detail: "\(Int((report.successRate * 100).rounded()))%"
        )
    }

    private var color: Color {
        switch report.state {
        case .healthy:
            return .mint
        case .degradedSoft, .degradedHard:
            return .yellow
        case .stalled, .down, .connectedButUnusable:
            return .orange
        }
    }
}

private struct MacHealthStatusRow: View {
    let title: String
    let value: String
    let color: Color
    let theme: MacLiquidTheme
    var detail: String?

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.primaryText)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(color)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(theme.rowFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct MacRoutingWorkspace: View {
    @ObservedObject var model: DashboardModel
    let theme: MacLiquidTheme
    @State private var forceVPNException = ""
    @State private var bypassVPNException = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("Routing")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.primaryText)

                Spacer()

                Button {
                    model.reconnectVPNWithKillSwitch()
                } label: {
                    Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.teal)
                .disabled(reconnectDisabled)
                .help("Reconnect VPN with Kill Switch")
            }

            VStack(spacing: 16) {
                MacSettingsSectionCard(title: "Bypass VPN", theme: theme) {
                    routingInput("Domain or CIDR", text: $bypassVPNException, mode: .bypassVPN)
                    routingRules(mode: .bypassVPN)
                }

                MacSettingsSectionCard(title: "Through VPN", theme: theme) {
                    routingInput("Domain or CIDR", text: $forceVPNException, mode: .forceVPN)
                    routingRules(mode: .forceVPN)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var reconnectDisabled: Bool {
        model.vpnStatus == .connecting || model.vpnStatus == .disconnecting
    }

    private func routingInput(_ placeholder: String, text: Binding<String>, mode: RoutingExceptionMode) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                routingTextField(placeholder, text: text)
                    .frame(maxWidth: .infinity)
                routingAddButton(text: text, mode: mode)
            }

            VStack(alignment: .leading, spacing: 8) {
                routingTextField(placeholder, text: text)
                routingAddButton(text: text, mode: mode)
            }
        }
    }

    private func routingTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(9)
            .background(theme.rowFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func routingAddButton(text: Binding<String>, mode: RoutingExceptionMode) -> some View {
        Button {
            model.addRoutingException(value: text.wrappedValue, mode: mode)
            text.wrappedValue = ""
        } label: {
            Label("Add Item", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .tint(.teal)
        .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func routingRules(mode: RoutingExceptionMode) -> some View {
        VStack(spacing: 0) {
            ForEach(model.routingExceptions.rules.filter { $0.mode == mode }) { rule in
                HStack {
                    Image(systemName: "globe")
                        .foregroundStyle(theme.secondaryText)
                    Text(rule.value)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { rule.isEnabled },
                        set: { model.setRoutingExceptionEnabled(id: rule.id, isEnabled: $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Button(role: .destructive) {
                        model.deleteRoutingException(id: rule.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider().opacity(0.35)
                    .padding(.leading, 12)
            }
        }
        .background(theme.rowFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct MacProfilesWorkspace: View {
    @ObservedObject var model: DashboardModel
    let theme: MacLiquidTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("VPN Profiles")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                    Text("Import, rename, delete, or double-click a profile to reconnect through it.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer()
            }

            ServerRankingPanel(model: model)
                .frame(minHeight: 520)
        }
    }
}

private struct MacStatisticsWorkspace: View {
    @ObservedObject var model: DashboardModel
    let theme: MacLiquidTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Stat")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(theme.primaryText)

            liveHealthPanel
            channelsPanel
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var liveHealthPanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Live Health")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.primaryText)

            HStack(spacing: 18) {
                healthTile(title: "Provider", report: model.healthAssessment.directPath, seed: 0.18)
                healthTile(title: "Tunnel", report: model.healthAssessment.vpnPath, seed: 0.46)
                lastCheckTile
                    .frame(width: 270)
            }

            HStack(spacing: 14) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                Text(model.probeReliabilityDetail.replacingOccurrences(of: "Best check ", with: "Best check: "))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.tertiaryText)
            }
        }
        .padding(24)
        .macLiquidCard(theme, radius: 16)
    }

    private var channelsPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Channels")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.primaryText)

                Spacer()

                Menu {
                    Button("All Channels") {}
                    Button("Active") {}
                    Button("Connected") {}
                } label: {
                    HStack(spacing: 8) {
                        Text("All Channels")
                        Image(systemName: "chevron.down")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(theme.rowFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.stroke, lineWidth: 1))
                }
                .menuStyle(.borderlessButton)

                Button {} label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 34, height: 34)
                        .background(theme.rowFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.stroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            if model.channelStatistics.isEmpty {
                Text("No channel statistics yet.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 20)
            } else {
                VStack(spacing: 10) {
                    ForEach(model.channelStatistics) { channel in
                        channelStatisticsRow(channel)
                    }
                }

                Text("\(model.channelStatistics.count) channels total")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
            }
        }
        .padding(24)
        .macLiquidCard(theme, radius: 16)
    }

    private func healthTile(title: String, report: PathHealthReport, seed: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(healthColor(report.state))
                        .frame(width: 9, height: 9)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer()
            }

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(Int((report.successRate * 100).rounded()))%")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(healthColor(report.state))
                    Text("\(formatLatency(report.averageLatencyMilliseconds))  •  \(formatPercent(report.averagePacketLoss)) loss")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                MacSparklineView(color: healthColor(report.state), seed: seed, fill: true)
                    .frame(width: 150, height: 54)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 106, alignment: .leading)
        .background(theme.rowFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.stroke, lineWidth: 1))
    }

    private var lastCheckTile: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Last Check", systemImage: "clock")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            Text(lastCheckText)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.blue)
            Text(model.lastProbeDate == nil ? "Waiting for probes" : "Updated just now")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(18)
        .frame(minHeight: 106, alignment: .leading)
        .background(theme.rowFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.stroke, lineWidth: 1))
    }

    private func channelStatisticsRow(_ channel: VPNChannelStatistics) -> some View {
        HStack(spacing: 18) {
            Image(systemName: "circle.grid.3x3.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.tertiaryText)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(regionMarker(channel.regionCode))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .frame(width: 28, height: 20)
                        .background(theme.selectedFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text(channel.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    if channel.isConnected {
                        channelBadge("Connected", color: .green)
                    } else if channel.isActive {
                        channelBadge("Active", color: .teal)
                    }
                }
                Text("\(channel.regionCode) · \(protocolLabel(channel.protocolKind)) · \(channel.sampleCount) samples")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(minWidth: 230, maxWidth: 290, alignment: .leading)

            channelMetric("Latency", formatLatency(channel.averageLatencyMilliseconds), sparkSeed: 0.18)
            channelMetric("Loss", formatPercent(channel.averagePacketLoss), sparkSeed: 0.30)
            channelMetric("Success", formatPercent(channel.successRate), sparkSeed: 0.44)
            channelMetric("Handshake", formatLatency(channel.averageHandshakeMilliseconds), sparkSeed: 0.58)
            channelMetric("Failures", "\(channel.failureCount)", sparkSeed: nil)
            channelMetric("Last", relativeTime(channel.lastSeen), sparkSeed: nil)

            VStack(alignment: .trailing, spacing: 2) {
                Text(channel.ranking.map { "\(Int(($0.score * 100).rounded()))" } ?? "--")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.teal)
                Text("score")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(theme.rowFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.stroke, lineWidth: 1))
    }

    private func channelBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }

    private func channelMetric(_ title: String, _ value: String, sparkSeed: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let sparkSeed {
                MacSparklineView(color: .green, seed: sparkSeed, fill: false)
                    .frame(width: 48, height: 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lastCheckText: String {
        guard let date = model.lastProbeDate else {
            return "--"
        }

        return relativeTime(date)
    }

    private func formatLatency(_ value: Double?) -> String {
        guard let value else {
            return "--"
        }

        return "\(Int(value.rounded())) ms"
    }

    private func formatPercent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func relativeTime(_ date: Date?) -> String {
        guard let date else {
            return "--"
        }

        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        return "\(minutes / 60)h"
    }

    private func protocolLabel(_ protocolKind: VPNProtocolKind) -> String {
        switch protocolKind {
        case .amneziaWG:
            return "AmneziaWG"
        case .wireGuard:
            return "WireGuard"
        case .singBox:
            return "sing-box"
        case .xray:
            return "Xray"
        case .openVPN:
            return "OpenVPN"
        case .unknown:
            return "VPN"
        }
    }

    private func regionMarker(_ regionCode: String) -> String {
        String(regionCode.prefix(2)).uppercased()
    }

    private func healthColor(_ state: PathHealthState) -> Color {
        switch state {
        case .healthy:
            return .green
        case .degradedSoft, .degradedHard:
            return .orange
        case .stalled, .down, .connectedButUnusable:
            return .red
        }
    }
}

private struct MacSparklineView: View {
    let color: Color
    let seed: Double
    var fill: Bool

    var body: some View {
        GeometryReader { proxy in
            let points = sparkPoints(in: proxy.size)
            ZStack {
                if fill {
                    sparkFill(points: points, size: proxy.size)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.20), color.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                sparkLine(points: points)
                    .stroke(color, style: StrokeStyle(lineWidth: fill ? 2 : 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func sparkPoints(in size: CGSize) -> [CGPoint] {
        let values = (0..<16).map { index -> Double in
            let wave = sin(Double(index) * 0.72 + seed * 8) * 0.18
            let trend = Double(index) / 20
            let bump = index > 10 ? 0.18 : 0
            return min(0.92, max(0.12, 0.38 + wave + trend + bump))
        }
        return values.enumerated().map { index, value in
            CGPoint(
                x: CGFloat(index) / CGFloat(max(values.count - 1, 1)) * size.width,
                y: size.height - CGFloat(value) * size.height
            )
        }
    }

    private func sparkLine(points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
    }

    private func sparkFill(points: [CGPoint], size: CGSize) -> Path {
        Path { path in
            guard let first = points.first, let last = points.last else { return }
            path.move(to: CGPoint(x: first.x, y: size.height))
            path.addLine(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.addLine(to: CGPoint(x: last.x, y: size.height))
            path.closeSubpath()
        }
    }
}

private struct MacSettingsWorkspace: View {
    @ObservedObject var model: DashboardModel
    @Binding var selectedSection: MacSettingsSection
    let theme: MacLiquidTheme
    @AppStorage("appVisibilityMode") private var appVisibilityModeRaw = AppVisibilityMode.dockAndMenuBar.rawValue
    @State private var amneziaKey = ""
    @State private var message: String?
    @State private var showConfigImporter = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                settingsSidebar
                    .frame(width: 170)

                settingsMainContent
            }
            .frame(minWidth: 760)

            VStack(alignment: .leading, spacing: 16) {
                compactSettingsTabs
                settingsMainContent
            }
        }
        .onAppear {
            amneziaKey = model.loadAmneziaPremiumKeyForEditing()
        }
        .fileImporter(
            isPresented: $showConfigImporter,
            allowedContentTypes: [.plainText, .json, .url, .data, UTType(filenameExtension: "conf") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            importFileResult(result)
        }
    }

    private var settingsMainContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(selectedSection.rawValue)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.primaryText)

            settingsContent

            if let message {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(message.localizedCaseInsensitiveContains("could not") || message.localizedCaseInsensitiveContains("cannot") ? .orange : .mint)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var settingsSidebar: some View {
        VStack(spacing: 8) {
            ForEach(MacSettingsSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    Label(section.rawValue, systemImage: section.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .foregroundStyle(selectedSection == section ? theme.accent : theme.secondaryText)
                        .background(selectedSection == section ? theme.selectedFill : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var compactSettingsTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MacSettingsSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        Label(section.rawValue, systemImage: section.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .foregroundStyle(selectedSection == section ? theme.accent : theme.secondaryText)
                            .background(selectedSection == section ? theme.selectedFill : theme.rowFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch selectedSection {
        case .general:
            generalSettings
        case .regions:
            regionsSettings
        case .security:
            securitySettings
        }
    }

    private var generalSettings: some View {
        VStack(spacing: 16) {
            MacSettingsSectionCard(title: "Appearance", theme: theme) {
                settingsToggle("Show in Menu Bar", isOn: Binding(
                    get: { appVisibilityMode.showsMenuBar },
                    set: { enabled in
                        if enabled {
                            appVisibilityModeRaw = appVisibilityMode == .dockOnly
                                ? AppVisibilityMode.dockAndMenuBar.rawValue
                                : appVisibilityMode.rawValue
                        } else {
                            appVisibilityModeRaw = AppVisibilityMode.dockOnly.rawValue
                        }
                    }
                ))
                settingsToggle("Show in Dock", isOn: Binding(
                    get: { appVisibilityMode != .menuBarOnly },
                    set: { enabled in
                        appVisibilityModeRaw = enabled
                            ? AppVisibilityMode.dockAndMenuBar.rawValue
                            : AppVisibilityMode.menuBarOnly.rawValue
                    }
                ))
                settingsToggle("Launch at Login", isOn: $model.launchAtLoginEnabled)
            }

            MacSettingsSectionCard(title: "Behavior", theme: theme) {
                settingsToggle("Connect to start", isOn: $model.connectOnStartEnabled)
                settingsToggle("Reconnect to VPN after dropped or reset", isOn: $model.reconnectAfterDropEnabled)
                settingsToggle("Auto-switch when connection is unstable", isOn: $model.automaticFailoverEnabled)
                settingsToggle("Show notification after switch", isOn: $model.showFailoverNotifications)
            }

            MacSettingsSectionCard(title: "Language", theme: theme) {
                Picker("Language", selection: $model.preferredLanguage) {
                    Text("English").tag("English")
                    Text("Русский").tag("Русский")
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var connectionSettings: some View {
        MacSettingsSectionCard(title: "Amnezia Profiles", theme: theme) {
            if model.configProfiles.isEmpty {
                Text("No imported profiles yet.")
                    .foregroundStyle(theme.secondaryText)
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
            }

            SecureField("Paste Amnezia Premium key, vpn:// link, or raw config", text: $amneziaKey)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(10)
                .background(theme.rowFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(theme.stroke, lineWidth: 1))

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

                Button("Import .conf / JSON") {
                    showConfigImporter = true
                }
                .buttonStyle(.bordered)

                Button("Delete Active", role: .destructive) {
                    if let error = model.deleteActiveConfigProfile() {
                        message = error
                    } else {
                        amneziaKey = ""
                        message = "Deleted active profile."
                    }
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }
        }
    }

    private var regionsSettings: some View {
        VStack(spacing: 16) {
            MacSettingsSectionCard(title: "Current Regions", theme: theme) {
                regionRow("Current Region", value: "\(model.currentRegion.rawValue) - Russia")
                regionRow("Home Region", value: "\(model.homeRegion.rawValue) - Israel")
            }
            MacSettingsSectionCard(title: "Preferred Exit Regions", theme: theme) {
                ForEach(Array(model.configProfiles.prefix(6))) { profile in
                    regionRow(profile.displayName, value: profile.regionCode ?? "Unknown")
                }
                if model.configProfiles.isEmpty {
                    Text("Import profiles to build a preferred region list.")
                        .foregroundStyle(theme.secondaryText)
                }
            }
            MacSettingsSectionCard(title: "Avoid Regions", theme: theme) {
                regionRow("Russia", value: "RU")
                regionRow("Belarus", value: "BY")
                regionRow("China", value: "CN")
            }
        }
    }

    private var securitySettings: some View {
        VStack(spacing: 16) {
            MacSettingsSectionCard(title: "Security", theme: theme) {
                settingsToggle("Kill Switch", isOn: $model.killSwitchEnabled)
                settingsToggle("DNS Protection", isOn: $model.dnsProtectionEnabled)
                settingsToggle("Local Network Access", isOn: $model.localNetworkAccessEnabled)
                settingsToggle("IPv6 Leak Protection", isOn: $model.ipv6LeakProtectionEnabled)
                settingsToggle("Auto Recovery", isOn: $model.automaticFailoverEnabled)
            }

            Button(role: .destructive) {
                model.killSwitchEnabled = false
                model.dnsProtectionEnabled = true
                model.localNetworkAccessEnabled = true
                model.ipv6LeakProtectionEnabled = true
                model.automaticFailoverEnabled = true
            } label: {
                Label("Reset Security Settings", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    private func settingsToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 18) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            Spacer(minLength: 24)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.teal)
                .frame(width: 52, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 3)
    }

    private func regionRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
            Spacer()
            Text(value)
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.vertical, 5)
    }

    private var appVisibilityMode: AppVisibilityMode {
        AppVisibilityMode(rawValue: appVisibilityModeRaw) ?? .dockAndMenuBar
    }

    private func profileRowTitle(_ profile: StoredAmneziaConfigProfile) -> String {
        [profile.displayName, profile.regionCode, profile.endpointHost]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func importFileResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                }
                let imported = try String(contentsOf: url, encoding: .utf8)
                Task {
                    if let error = await model.importAmneziaConfigProfile(name: url.lastPathComponent, rawConfig: imported) {
                        message = error
                    } else {
                        amneziaKey = model.loadAmneziaPremiumKeyForEditing()
                        message = "Imported \(url.lastPathComponent) as active profile."
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

private struct MacSettingsSectionCard<Content: View>: View {
    let title: String
    let theme: MacLiquidTheme
    let content: Content

    init(title: String, theme: MacLiquidTheme, @ViewBuilder content: () -> Content) {
        self.title = title
        self.theme = theme
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.primaryText)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macLiquidCard(theme)
    }
}

private struct MacAboutWorkspace: View {
    let buildLabel: String
    let theme: MacLiquidTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("About")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(theme.primaryText)
            VStack(alignment: .leading, spacing: 10) {
                Text("Real Ai Router")
                    .font(.system(size: 22, weight: .bold))
                Text("v\(buildLabel)")
                    .foregroundStyle(theme.secondaryText)
                Text("Smart VPN routing with local profile quality history, health probes, recovery, and region-aware exceptions.")
                    .foregroundStyle(theme.secondaryText)
            }
            .padding(22)
            .macLiquidCard(theme)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

                Text(model.dnsPolicyDiagnostic)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(2)
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
    @Environment(\.colorScheme) private var colorScheme
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
            Text("If this profile is connected, Real Ai Router will switch to the next available profile automatically.")
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
                        .foregroundStyle(ranked.server.id == model.activeServerID ? .teal : secondaryText.opacity(0.62))
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(ranked.server.displayName)
                            .font(.system(size: 14, weight: .semibold))
                        Text("\(ranked.server.region.rawValue) · \(ranked.reason)")
                            .font(.system(size: 11))
                            .foregroundStyle(secondaryText)
                    }

                    Spacer()

                    ProgressView(value: ranked.score)
                        .progressViewStyle(.linear)
                        .tint(.teal)
                        .frame(width: 128)

                    Text("\(Int(ranked.score * 100))")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(primaryText)
                        .frame(width: 34, alignment: .trailing)
                }
                .padding(12)
                .background(rowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                        .background(
                            profile.id == model.displayedConfigProfile?.id ? selectedRowBackground : rowBackground,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
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
        .frame(minHeight: 0, maxHeight: .infinity)
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
                .foregroundStyle(profile.id == model.displayedConfigProfile?.id ? .teal : secondaryText.opacity(0.62))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
                Text(profileDetail(profile))
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
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
        .foregroundStyle(primaryText.opacity(0.82))
    }

    private var primaryText: Color {
        colorScheme == .dark ? .white : Color(red: 0.10, green: 0.13, blue: 0.18)
    }

    private var secondaryText: Color {
        colorScheme == .dark ? .white.opacity(0.62) : Color(red: 0.38, green: 0.43, blue: 0.50)
    }

    private var rowBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.72)
    }

    private var selectedRowBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.11) : Color.teal.opacity(0.10)
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
    @Environment(\.colorScheme) private var colorScheme
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
                    .foregroundStyle(secondaryText)
                Spacer()
                accessory
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(18)
        .frame(minHeight: 210)
        .background(.ultraThinMaterial.opacity(colorScheme == .dark ? 0.72 : 0.86), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(panelFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(strokeColor, lineWidth: 1)
        )
    }

    private var secondaryText: Color {
        colorScheme == .dark ? .white.opacity(0.72) : Color(red: 0.34, green: 0.39, blue: 0.45)
    }

    private var panelFill: Color {
        colorScheme == .dark ? .white.opacity(0.04) : .white.opacity(0.56)
    }

    private var strokeColor: Color {
        colorScheme == .dark ? .white.opacity(0.12) : .black.opacity(0.06)
    }
}

struct SettingsView: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appVisibilityMode") private var appVisibilityModeRaw = AppVisibilityMode.dockAndMenuBar.rawValue
    @State private var amneziaKey = ""
    @State private var message: String?
    @State private var selectedTab: SettingsTab = .app
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
                Picker("Show Real Ai Router", selection: Binding(
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

                Text("When the active VPN path stalls, Real Ai Router switches to the best imported profile, reconnects, and shows a confirmation popup.")
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
