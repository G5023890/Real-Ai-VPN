import AmneziaConfig
import AppKit
import Combine
import RealVPNCore
import SwiftUI
import SmartServerSelection
import UniformTypeIdentifiers

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
    @Environment(\.openWindow) private var openWindow
    @AppStorage("appVisibilityMode") private var appVisibilityModeRaw = AppVisibilityMode.dockAndMenuBar.rawValue
    @StateObject private var model = DashboardModel()
    @State private var showSettings = false

    init() {
        Self.applyActivationPolicy(for: Self.storedVisibilityMode())
    }

    var body: some Scene {
        WindowGroup(id: "main") {
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
}

struct MenuBarIcon: View {
    var isConnected: Bool

    var body: some View {
        if isConnected {
            ActiveMenuBarShieldIcon()
                .frame(width: 18, height: 18)
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
        ZStack {
            Image(systemName: "shield.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.primary)

            Text("A")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .offset(y: -0.5)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .accessibilityLabel("Real Ai VPN connected")
    }
}

@MainActor
final class DashboardModel: ObservableObject {
    enum StoredConfigKind: String {
        case none = "No Config"
        case premiumToken = "Premium Token"
        case awgConfig = "AWG Config"
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
    @Published private(set) var hasAmneziaPremiumKey = false
    @Published private(set) var storedConfigKind: StoredConfigKind = .none
    @Published private(set) var configProfiles: [StoredAmneziaConfigProfile] = []
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
    private let vpnManager = RealVPNProfileManager()
    private let premiumKeyStore = AmneziaPremiumKeyStore(accessGroup: AmneziaPremiumKeyStore.sharedAccessGroup)
    private let profileStore = AmneziaConfigProfileStore(accessGroup: AmneziaPremiumKeyStore.sharedAccessGroup)
    private lazy var monitor = PreventiveVPNHealthMonitor(selector: selector)
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let directReport = PathHealthReport(
            state: .healthy,
            successRate: 1,
            averageLatencyMilliseconds: 24,
            averagePacketLoss: 0,
            consecutiveFailures: 0,
            reason: "healthy"
        )
        let vpnReport = PathHealthReport(
            state: .healthy,
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
        bindVPNManagerState()
        refresh()
        refreshPremiumKeyState()
        Task {
            await vpnManager.prepareProfile(configuration: vpnConfiguration)
        }
    }

    var activeConfigProfile: StoredAmneziaConfigProfile? {
        guard let activeConfigProfileID else {
            return configProfiles.first
        }

        return configProfiles.first { $0.id == activeConfigProfileID } ?? configProfiles.first
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

    var context: ServerSelectionContext {
        ServerSelectionContext(
            currentRegion: currentRegion,
            homeRegion: homeRegion,
            networkKind: .wifi,
            providerASN: "AS12389",
            hourOfDay: Calendar.current.component(.hour, from: Date()),
            previousServerID: activeServerID
        )
    }

    func refresh() {
        routeDecision = selector.decideRoute(
            destinationRegion: selectedDestination,
            context: context,
            servers: servers
        )
        rankedServers = selector.rankedServers(context: context, servers: servers)
        healthAssessment = monitor.assess(
            probes: probes(for: scenario),
            activeServerID: activeServerID,
            context: context,
            servers: servers
        )
    }

    func applyRecoveryAction() {
        switch healthAssessment.recommendedAction {
        case .switchServer(_, let to, _):
            activeServerID = to
        case .reconnect(let serverID, _), .adjustParameters(let serverID, _, _):
            activeServerID = serverID
        case .keepCurrent, .refreshDirectDNS, .askUser:
            break
        }

        scenario = .healthy
        refresh()
    }

    func connectVPN() {
        guard !vpnStatus.isConnectedOrConnecting else {
            return
        }

        vpnStatus = .connecting
        vpnErrorMessage = nil
        Task {
            let amneziaKey = activeConfigProfile?.config ?? (try? premiumKeyStore.read())
            guard let amneziaKey, !amneziaKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                vpnErrorMessage = "Import an AmneziaWG .conf profile in Settings before connecting."
                vpnStatus = .disconnected
                return
            }

            do {
                _ = try amneziaDecoder.decodeImportedWireGuardConfig(from: amneziaKey)
            } catch {
                vpnErrorMessage = "The saved Amnezia config cannot be used yet: \(error.localizedDescription)"
                vpnStatus = .disconnected
                return
            }

            await vpnManager.connect(configuration: vpnConfiguration, transientAmneziaKey: amneziaKey)
        }
    }

    func disconnectVPN() {
        guard vpnStatus.isConnectedOrConnecting else {
            return
        }

        vpnStatus = .disconnecting
        vpnManager.disconnect()
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
        do {
            let decoded = try amneziaDecoder.decodeImportedWireGuardConfig(from: rawConfig)
            let profile = makeProfile(name: name, rawConfig: rawConfig, decodedConfig: decoded)
            try profileStore.upsert(profile)
            try premiumKeyStore.save(rawConfig)
            refreshPremiumKeyState()
            vpnErrorMessage = nil
            return nil
        } catch {
            refreshPremiumKeyState()
            return "The Amnezia config cannot be used yet: \(error.localizedDescription)"
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

        do {
            try profileStore.deleteProfile(id: id)
            refreshPremiumKeyState()
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
                self?.vpnStatus = status
            }
            .store(in: &cancellables)

        vpnManager.$lastErrorMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                self?.vpnErrorMessage = self?.userFacingVPNError(message)
            }
            .store(in: &cancellables)
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

        if trimmed.hasPrefix("vpn://") {
            return .premiumToken
        }

        return .unknown
    }

    private var vpnConfiguration: VPNProfileConfiguration {
        let server = servers.first { $0.id == activeServerID } ?? servers[0]
        let activeProfile = activeConfigProfile

        return VPNProfileConfiguration(
            serverID: activeProfile?.endpointHost ?? server.id,
            regionCode: activeProfile?.regionCode ?? server.region.rawValue
        )
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
        .onChange(of: model.scenario) {
            model.refresh()
        }
        .onChange(of: model.selectedDestination) {
            model.refresh()
        }
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
                Text(titleSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.62))
            }

            Spacer()

            Picker("", selection: $model.selectedDestination) {
                Text("Russia").tag(DestinationRegion.current)
                Text("Israel").tag(DestinationRegion.home)
                Text("Foreign").tag(DestinationRegion.foreign)
            }
            .pickerStyle(.segmented)
            .frame(width: 260)

            Picker("", selection: $model.scenario) {
                ForEach(DashboardModel.ProbeScenario.allCases) { scenario in
                    Text(scenario.rawValue).tag(scenario)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)

            Button {
                model.toggleVPN()
            } label: {
                Label(connectButtonTitle, systemImage: connectButtonSymbol)
                    .frame(width: 132)
            }
            .buttonStyle(.borderedProminent)
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
                    Text(routeTitle)
                        .font(.system(size: 34, weight: .bold))
                        .minimumScaleFactor(0.75)
                        .lineLimit(1)

                    Text(routeSource)
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
                        Text(error)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
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
                }
            }
        }
    }

    private var routeTitle: String {
        switch model.routeDecision.action {
        case .directProviderDNS:
            return "Direct Provider DNS"
        case .vpn(_, let region):
            return model.vpnStatus == .connected ? "VPN \(region.rawValue)" : "Planned VPN \(region.rawValue)"
        case .ask:
            return "Needs Attention"
        }
    }

    private var routeSource: String {
        model.vpnStatus == .connected ? model.routeDecision.source : "\(model.routeDecision.source) · policy preview"
    }

    private var gaugeValue: Double {
        model.routeDecision.rankedServers.first?.confidence ?? 1
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

                Text(model.vpnStatus.isConnectedOrConnecting ? "Live tunnel probes" : "Provider check is simulated until VPN connects")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

struct ServerRankingPanel: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        Panel(title: model.configProfiles.isEmpty ? "Servers" : "Imported Profiles", symbol: "server.rack") {
            if model.configProfiles.isEmpty {
                rankedServerRows
            } else {
                importedProfileRows
            }
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
            ForEach(model.configProfiles) { profile in
                Button {
                    model.activeConfigProfileID = profile.id
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: profile.id == model.activeConfigProfile?.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(profile.id == model.activeConfigProfile?.id ? .teal : .white.opacity(0.38))
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.displayName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                            Text(profileDetail(profile))
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.62))
                                .lineLimit(1)
                        }

                        Spacer()

                        Text(profile.kind.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.teal)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.teal.opacity(0.14), in: Capsule())
                    }
                    .padding(12)
                    .background(.white.opacity(profile.id == model.activeConfigProfile?.id ? 0.11 : 0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
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
        parts.append(profile.id == model.activeConfigProfile?.id ? "active" : "standby")
        return parts.joined(separator: " · ")
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
            return model.vpnStatus.isConnectedOrConnecting ? "Keep Current" : "Ready to Connect"
        case .refreshDirectDNS:
            return "Refresh DNS"
        case .reconnect:
            return "Reconnect"
        case .switchServer(_, let to, _):
            return "Switch to \(to)"
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
            return reason
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

struct Panel<Content: View>: View {
    var title: String
    var symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(.teal)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
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
            allowedContentTypes: [.plainText, .data, UTType(filenameExtension: "conf") ?? .data],
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
                    if let error = model.importAmneziaConfigProfile(name: url.lastPathComponent, rawConfig: imported) {
                        message = error
                    } else {
                        amneziaKey = imported
                        message = "Imported \(url.lastPathComponent) as the active profile."
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
                        set: { model.activeConfigProfileID = $0.isEmpty ? nil : $0 }
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
        case .degraded:
            return .yellow
        case .stalled:
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
