import AmneziaConfig
import Combine
import Network
import RealVPNCore
import SmartServerSelection
import SwiftUI
import UIKit
import UserNotifications
import UniformTypeIdentifiers
import os

private let iosAppLogger = Logger(
    subsystem: "com.codex.RealAiVPN",
    category: "iOSDashboard"
)

private final class iOSNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
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

private enum ConnectivityProbeRunner {
    static func tcpConnect(host: String, port: UInt16, timeout: TimeInterval = 4) async -> (succeeded: Bool, latency: Double?) {
        await withCheckedContinuation { continuation in
            let start = Date()
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? 443,
                using: .tcp
            )
            let queue = DispatchQueue(label: "RealAiVPN.iOS.TCPProbe.\(host)")
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
}

private struct StoredProfileQualityHistory: Codable {
    var samples: [ServerQualitySample]
}

private struct StoredProbeReliabilityHistory: Codable {
    var probes: [ConnectivityProbeResult]
}

private struct LocalProfileQualityHistoryStore {
    private let key = "ios.profileQualityHistory.v1"
    private let maxSamples = 240

    func load() -> [ServerQualitySample] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let history = try? JSONDecoder().decode(StoredProfileQualityHistory.self, from: data) else {
            return []
        }

        return Array(history.samples.suffix(maxSamples))
    }

    func save(_ samples: [ServerQualitySample]) {
        let history = StoredProfileQualityHistory(samples: Array(samples.suffix(maxSamples)))
        guard let data = try? JSONEncoder().encode(history) else {
            return
        }

        UserDefaults.standard.set(data, forKey: key)
    }
}

private struct LocalProbeReliabilityHistoryStore {
    private let key = "ios.probeReliabilityHistory.v1"
    private let maxSamples = 960

    func load() -> [ConnectivityProbeResult] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let history = try? JSONDecoder().decode(StoredProbeReliabilityHistory.self, from: data) else {
            return []
        }

        return Array(history.probes.suffix(maxSamples))
    }

    func save(_ probes: [ConnectivityProbeResult]) {
        let history = StoredProbeReliabilityHistory(probes: Array(probes.suffix(maxSamples)))
        guard let data = try? JSONEncoder().encode(history) else {
            return
        }

        UserDefaults.standard.set(data, forKey: key)
    }
}

private struct ProfileEndpoint {
    var host: String
    var port: UInt16
}

@main
struct RealAiVPNiOSApp: App {
    private static let notificationDelegate = iOSNotificationDelegate()
    @StateObject private var model = iOSDashboardModel()

    init() {
        let center = UNUserNotificationCenter.current()
        center.delegate = Self.notificationDelegate
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var body: some Scene {
        WindowGroup {
            iOSDashboardView(model: model)
        }
    }
}

@MainActor
final class iOSDashboardModel: ObservableObject {
    @Published private(set) var profiles: [StoredAmneziaConfigProfile] = []
    @Published private(set) var activeProfileID: String?
    @Published private(set) var vpnStatus: VPNConnectionStatus = .unknown
    @Published private(set) var vpnLastError: String?
    @Published private(set) var vpnProviderBundleIdentifier: String?
    @Published private(set) var tunnelDiagnostic: TunnelDiagnosticSnapshot?
    @Published private(set) var message = "Import an AmneziaWG .conf profile to start."
    @Published private(set) var routeTitle = "Ready"
    @Published private(set) var confidence = 0
    @Published private(set) var routingExceptions = RoutingExceptionCollection()
    @Published private(set) var healthAssessment = PreventiveHealthAssessment(
        directPath: PathHealthReport(
            state: .healthy,
            successRate: 1,
            averageLatencyMilliseconds: nil,
            averagePacketLoss: 0,
            consecutiveFailures: 0,
            reason: "collecting"
        ),
        vpnPath: PathHealthReport(
            state: .down,
            successRate: 0,
            averageLatencyMilliseconds: nil,
            averagePacketLoss: 1,
            consecutiveFailures: 0,
            reason: "collecting"
        ),
        recommendedAction: .askUser(reason: "collecting")
    )
    @Published private(set) var rankedServers: [RankedServer] = []
    @Published private(set) var lastProbeDate: Date?
    @Published var automaticFailoverEnabled = UserDefaults.standard.object(forKey: "ios.automaticFailoverEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automaticFailoverEnabled, forKey: "ios.automaticFailoverEnabled")
        }
    }

    private let decoder = AmneziaConfigDecoder()
    private let shadowrocketParser = ShadowrocketVLESSConfigParser()
    private let profileStore = AmneziaConfigProfileStore(accessGroup: AmneziaPremiumKeyStore.sharedAccessGroup)
    private let routingExceptionStore = RoutingExceptionStore()
    private let tunnelDiagnosticsStore = TunnelDiagnosticsStore()
    private let vpnManager = RealVPNProfileManager()
    private let selector = SmartServerSelector()
    private let qualityHistoryStore = LocalProfileQualityHistoryStore()
    private let probeReliabilityHistoryStore = LocalProbeReliabilityHistoryStore()
    private let probeReliabilityAnalyzer = ProbeReliabilityAnalyzer()
    private lazy var monitor = PreventiveVPNHealthMonitor(selector: selector, reliabilityAnalyzer: probeReliabilityAnalyzer)
    private var cancellables: Set<AnyCancellable> = []
    private var qualitySamples: [ServerQualitySample] = []
    private var probeReliabilitySamples: [ConnectivityProbeResult] = []
    private var liveProbeResults: [ConnectivityProbeResult] = []
    private var monitoringTask: Task<Void, Never>?
    private var lastAutomaticFailoverDate: Date?
    private var suppressExpectedDisconnectNotification = false

    init() {
        vpnManager.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.handleVPNStatusChange(status)
                self?.refreshStatusMessage()
            }
            .store(in: &cancellables)
        vpnManager.$lastErrorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.vpnLastError = error
                self?.refreshStatusMessage()
            }
            .store(in: &cancellables)
        vpnManager.$lastProviderBundleIdentifier
            .receive(on: DispatchQueue.main)
            .sink { [weak self] provider in
                self?.vpnProviderBundleIdentifier = provider
            }
            .store(in: &cancellables)
        reloadProfiles()
        reloadRoutingExceptions()
        loadQualityHistory()
        loadProbeReliabilityHistory()
        requestNotificationPermission()
        startMonitoring()
        Task {
            await vpnManager.prepareProfile(configuration: vpnConfiguration)
        }
    }

    deinit {
        monitoringTask?.cancel()
    }

    var isConnectedOrConnecting: Bool {
        vpnStatus.isConnectedOrConnecting
    }

    var activeProfile: StoredAmneziaConfigProfile? {
        guard let activeProfileID else {
            return profiles.first
        }
        return profiles.first { $0.id == activeProfileID } ?? profiles.first
    }

    var confidenceDetail: String {
        guard let lastProbeDate else {
            return "collecting live probes"
        }

        let age = max(0, Int(Date().timeIntervalSince(lastProbeDate)))
        let sampleCount = activeProfile.map { profile in
            qualitySamples.filter { $0.serverID == profile.id }.count
        } ?? qualitySamples.count
        if let best = activeProfile.flatMap({ profile in
            probeReliabilityAnalyzer.bestSummary(
                from: probeReliabilitySamples,
                serverID: profile.id,
                targetKind: .vpnProtectedEndpoint
            )
        }) {
            return "\(sampleCount) samples · \(age)s ago · \(Int((best.reliabilityScore * 100).rounded()))% check"
        }

        return "\(sampleCount) samples · \(age)s ago"
    }

    var probeReliabilityDetail: String {
        guard let activeProfile,
              let best = probeReliabilityAnalyzer.bestSummary(
                from: probeReliabilitySamples,
                serverID: activeProfile.id,
                targetKind: .vpnProtectedEndpoint
              ) else {
            return "Probe reliability is learning on this profile."
        }

        return "Best check: \(best.targetID) · \(Int((best.reliabilityScore * 100).rounded()))% reliable."
    }

    var recoveryTitle: String {
        switch healthAssessment.recommendedAction {
        case .keepCurrent:
            return "Keep Current"
        case .refreshDirectDNS:
            return "Refresh DNS"
        case .reconnect:
            return "Reconnect"
        case .switchServer:
            return "Switch Profile"
        case .adjustParameters:
            return "Tune Tunnel"
        case .askUser:
            return "Needs Attention"
        }
    }

    var recoveryDetail: String {
        switch healthAssessment.recommendedAction {
        case .keepCurrent(let reason), .refreshDirectDNS(let reason), .reconnect(_, let reason),
             .switchServer(_, _, let reason), .adjustParameters(_, _, let reason), .askUser(let reason):
            return reason
        }
    }

    func importProfile(from url: URL) {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        var rawConfig = ""
        do {
            rawConfig = try String(contentsOf: url, encoding: .utf8)
            let displayName = url.deletingPathExtension().lastPathComponent
            Task {
                await importProfile(displayName: displayName, rawConfig: rawConfig)
            }
        } catch {
            message = Self.importErrorMessage(for: error, rawConfig: rawConfig)
        }
    }

    private func importProfile(displayName: String, rawConfig: String) async {
        do {
            if let subscriptionURL = try shadowrocketParser.subscriptionURL(from: rawConfig) {
                let subscriptionText = try await fetchSubscription(from: subscriptionURL)
                let entries = try shadowrocketParser.parseEntries(subscriptionText)
                try upsertShadowrocketEntries(entries, fallbackName: displayName, makeFirstActive: true)
                reloadProfiles()
                message = "Imported \(entries.count) VLESS profile\(entries.count == 1 ? "" : "s"). Ready to connect."
                return
            }

            let entries = (try? shadowrocketParser.parseEntries(rawConfig)) ?? []
            if !entries.isEmpty {
                try upsertShadowrocketEntries(entries, fallbackName: displayName, makeFirstActive: true)
                reloadProfiles()
                message = "Imported \(entries.count) VLESS profile\(entries.count == 1 ? "" : "s"). Ready to connect."
                return
            }

            let decoded = try decoder.decodeImportedWireGuardConfig(from: rawConfig)
            let endpointHost = Self.endpointHost(from: decoded.endpoint)
            let regionCode = Self.regionCode(from: displayName, endpointHost: endpointHost)
            let profile = StoredAmneziaConfigProfile(
                displayName: displayName,
                kind: .awgConfig,
                regionCode: regionCode,
                endpointHost: endpointHost,
                config: rawConfig
            )
            try profileStore.upsert(profile, makeActive: true)
            reloadProfiles()
            message = "Imported \(profile.displayName). Ready to connect."
        } catch {
            message = Self.importErrorMessage(for: error, rawConfig: rawConfig)
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
            let displayName = entry.profile.title.isEmpty ? fallbackName : entry.profile.title
            let profile = StoredAmneziaConfigProfile(
                displayName: displayName,
                kind: .singBoxVLESSReality,
                regionCode: entry.profile.regionCode ?? Self.regionCode(from: displayName, endpointHost: entry.profile.host),
                endpointHost: entry.profile.host,
                config: entry.rawConfig
            )
            try profileStore.upsert(profile, makeActive: makeFirstActive && index == 0)
        }
    }

    func setActiveProfile(id: String) {
        NSLog("RealAiVPN iOS setActiveProfile id=%@", id)
        do {
            try profileStore.setActiveProfile(id: id)
            reloadProfiles()
            NSLog("RealAiVPN iOS activeProfile=%@ kind=%@ endpoint=%@",
                  activeProfile?.displayName ?? "none",
                  activeProfile?.kind.rawValue ?? "none",
                  activeProfile?.endpointHost ?? "unknown")
            message = "Selected \(activeProfile?.displayName ?? "profile")."
        } catch {
            NSLog("RealAiVPN iOS setActiveProfile failed: %@", error.localizedDescription)
            message = "Could not select profile: \(error.localizedDescription)"
        }
    }

    func deleteProfile(id: String) {
        let deletingActiveProfile = activeProfile?.id == id
        let deletedName = profiles.first { $0.id == id }?.displayName ?? "profile"

        if deletingActiveProfile, vpnStatus.isConnectedOrConnecting {
            suppressExpectedDisconnectNotification = true
            vpnManager.disconnect()
        }

        do {
            try profileStore.deleteProfile(id: id)
            qualitySamples.removeAll { $0.serverID == id }
            qualityHistoryStore.save(qualitySamples)
            probeReliabilitySamples.removeAll { $0.serverID == id }
            probeReliabilityHistoryStore.save(probeReliabilitySamples)
            liveProbeResults.removeAll { $0.serverID == id }
            reloadProfiles()
            Task {
                await vpnManager.prepareProfile(configuration: vpnConfiguration)
            }
            message = profiles.isEmpty
                ? "Deleted \(deletedName). Import a profile to connect."
                : "Deleted \(deletedName). Active profile is \(activeProfile?.displayName ?? "profile")."
        } catch {
            message = "Could not delete \(deletedName): \(error.localizedDescription)"
        }
    }

    func connect() {
        NSLog("RealAiVPN iOS connect() entered connectedOrConnecting=%@", isConnectedOrConnecting ? "true" : "false")
        guard let activeProfile else {
            NSLog("RealAiVPN iOS connect() no active profile")
            message = "Import an AmneziaWG .conf profile first."
            return
        }

        Task {
            let connectProfile = await resolveProfileForConnect(activeProfile)
            iosAppLogger.info("Connect requested profile=\(connectProfile.displayName, privacy: .public) kind=\(connectProfile.kind.rawValue, privacy: .public) endpoint=\(connectProfile.endpointHost ?? "unknown", privacy: .public)")
            NSLog("RealAiVPN iOS Connect requested profile=%@ kind=%@ endpoint=%@ provider=%@",
                  connectProfile.displayName,
                  connectProfile.kind.rawValue,
                  connectProfile.endpointHost ?? "unknown",
                  providerBundleIdentifier(for: connectProfile))
            await vpnManager.connect(
                configuration: vpnConfiguration(for: connectProfile),
                transientAmneziaKey: connectProfile.config,
                routingExceptions: routingExceptions
            )
            tunnelDiagnostic = tunnelDiagnosticsStore.load()
            NSLog("RealAiVPN iOS connect() returned from vpnManager")
            refreshStatusMessage()
        }
    }

    func disconnect() {
        NSLog("RealAiVPN iOS disconnect() entered")
        suppressExpectedDisconnectNotification = true
        vpnManager.disconnect()
        message = "Disconnecting..."
    }

    func addRoutingException(value: String, mode: RoutingExceptionMode) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return
        }

        routingExceptions.rules.append(RoutingExceptionRule(value: normalized, mode: mode))
        routingExceptionStore.save(routingExceptions)
        message = "Routing exceptions will apply on the next reconnect."
    }

    func deleteRoutingException(id: String) {
        routingExceptions.rules.removeAll { $0.id == id }
        routingExceptionStore.save(routingExceptions)
        message = "Routing exceptions will apply on the next reconnect."
    }

    func setRoutingExceptionEnabled(id: String, isEnabled: Bool) {
        guard let index = routingExceptions.rules.firstIndex(where: { $0.id == id }) else {
            return
        }

        routingExceptions.rules[index].isEnabled = isEnabled
        routingExceptionStore.save(routingExceptions)
        message = "Routing exceptions will apply on the next reconnect."
    }

    private func reloadProfiles() {
        do {
            let collection = try profileStore.load()
            profiles = collection.profiles
            activeProfileID = collection.activeProfile?.id
            refreshRoutePreview()
            refreshStatusMessage()
        } catch {
            message = "Could not load profiles: \(error.localizedDescription)"
        }
    }

    private func reloadRoutingExceptions() {
        routingExceptions = routingExceptionStore.load()
    }

    private func refreshRoutePreview() {
        let servers = effectiveServers
        let context = ServerSelectionContext(
            currentRegion: RegionCode("RU"),
            homeRegion: RegionCode("IL"),
            networkKind: .wifi,
            providerASN: nil,
            hourOfDay: Calendar.current.component(.hour, from: Date()),
            previousServerID: activeProfileID
        )
        let decision = selector.decideRoute(
            destinationRegion: .foreign,
            context: context,
            servers: servers
        )
        rankedServers = selector.rankedServers(context: context, servers: servers)
        if !liveProbeResults.isEmpty {
            healthAssessment = monitor.assess(
                probes: liveProbeResults,
                activeServerID: activeProfile?.id,
                context: context,
                servers: servers,
                probeHistory: probeReliabilitySamples
            )
        }
        routeTitle = Self.routeTitle(for: decision, activeProfile: activeProfile, status: vpnStatus)
        let activeConfidence = activeProfile
            .flatMap { profile in rankedServers.first { $0.server.id == profile.id }?.confidence }
        confidence = Int(((activeConfidence ?? decision.rankedServers.first?.confidence ?? rankedServers.first?.confidence ?? 0) * 100).rounded())
    }

    private func refreshStatusMessage() {
        let profileName = activeProfile?.displayName ?? "profile"
        if let vpnLastError, !vpnLastError.isEmpty {
            message = vpnLastError
            refreshRoutePreview()
            return
        }
        switch vpnStatus {
        case .connected:
            message = "Connected to \(profileName)."
        case .connecting, .reasserting:
            message = "Connecting \(profileName)..."
        case .disconnecting:
            message = "Disconnecting from \(profileName)..."
        case .disconnected:
            message = profiles.isEmpty ? "Import an AmneziaWG .conf profile to start." : "Disconnected. Ready to connect \(profileName)."
        case .invalid:
            message = "VPN profile is invalid. Reinstall or recreate the VPN profile."
        case .unknown:
            message = profiles.isEmpty ? "Import an AmneziaWG .conf profile to start." : "Checking VPN status for \(profileName)..."
        }
        refreshRoutePreview()
    }

    private func handleVPNStatusChange(_ status: VPNConnectionStatus) {
        let previousStatus = vpnStatus
        vpnStatus = status

        guard status == .disconnected else {
            return
        }

        if suppressExpectedDisconnectNotification {
            suppressExpectedDisconnectNotification = false
            return
        }

        if previousStatus == .connected || previousStatus == .reasserting {
            notifyTunnelDropped(profile: activeProfile?.displayName ?? "profile")
        }
    }

    private func notifyTunnelDropped(profile: String) {
        let content = UNMutableNotificationContent()
        content.title = "Real Ai VPN disconnected"
        content.body = "Tunnel dropped or reset for \(profile)."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "real-ai-vpn-ios-disconnect-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private var vpnConfiguration: VPNProfileConfiguration {
        vpnConfiguration(for: activeProfile)
    }

    private func vpnConfiguration(for profile: StoredAmneziaConfigProfile?) -> VPNProfileConfiguration {
        VPNProfileConfiguration(
            localizedDescription: localizedVPNDescription(for: profile),
            providerBundleIdentifier: providerBundleIdentifier(for: profile),
            serverID: profile?.id ?? "real-ai-vpn-ios",
            regionCode: profile?.regionCode ?? "ZZ"
        )
    }

    private func localizedVPNDescription(for profile: StoredAmneziaConfigProfile?) -> String {
        profile?.kind == .singBoxVLESSReality ? "Real Ai VPN VLESS" : "Real Ai VPN AWG"
    }

    private func providerBundleIdentifier(for profile: StoredAmneziaConfigProfile?) -> String {
        profile?.kind == .singBoxVLESSReality
            ? "com.codex.RealAiVPN.iOS.SingBoxPacketTunnel"
            : "com.codex.RealAiVPN.iOS.PacketTunnel"
    }

    private func resolveProfileForConnect(_ profile: StoredAmneziaConfigProfile) async -> StoredAmneziaConfigProfile {
        guard profile.kind != .singBoxVLESSReality else {
            return profile
        }

        if let repaired = await repairLegacyShadowrocketProfileIfNeeded(profile) {
            return repaired
        }

        return profile
    }

    private func repairLegacyShadowrocketProfileIfNeeded(_ profile: StoredAmneziaConfigProfile) async -> StoredAmneziaConfigProfile? {
        let rawConfig = profile.config.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawConfig.isEmpty else {
            return nil
        }

        do {
            NSLog("RealAiVPN iOS repairLegacyShadowrocketProfileIfNeeded profile=%@ kind=%@",
                  profile.displayName,
                  profile.kind.rawValue)
            let entries: [ShadowrocketVLESSProfileEntry]
            if let subscriptionURL = try shadowrocketParser.subscriptionURL(from: rawConfig) {
                iosAppLogger.info("Repairing legacy Shadowrocket subscription profile=\(profile.displayName, privacy: .public)")
                NSLog("RealAiVPN iOS repairing Shadowrocket subscription profile=%@", profile.displayName)
                let subscriptionText = try await fetchSubscription(from: subscriptionURL)
                entries = try shadowrocketParser.parseEntries(subscriptionText)
            } else {
                entries = (try? shadowrocketParser.parseEntries(rawConfig)) ?? []
            }

            NSLog("RealAiVPN iOS legacy Shadowrocket parsed entries=%ld", entries.count)
            guard !entries.isEmpty else {
                return nil
            }

            try upsertShadowrocketEntries(entries, fallbackName: profile.displayName, makeFirstActive: true)
            try profileStore.deleteProfile(id: profile.id)
            reloadProfiles()

            if let repaired = activeProfile, repaired.kind == .singBoxVLESSReality {
                NSLog("RealAiVPN iOS repaired active profile=%@ endpoint=%@",
                      repaired.displayName,
                      repaired.endpointHost ?? "unknown")
                message = "Converted Shadowrocket profile to VLESS Reality. Connecting \(repaired.displayName)..."
                return repaired
            }
        } catch {
            NSLog("RealAiVPN iOS legacy Shadowrocket repair failed: %@", error.localizedDescription)
            iosAppLogger.error("Could not repair Shadowrocket profile: \(error.localizedDescription, privacy: .public)")
            message = "Could not prepare Shadowrocket profile: \(error.localizedDescription)"
        }

        return nil
    }

    private var effectiveServers: [SmartVPNServer] {
        profiles.map { profile in
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

    private func loadQualityHistory() {
        qualitySamples = qualityHistoryStore.load()
        qualitySamples.forEach { selector.record($0) }
        refreshRoutePreview()
    }

    private func loadProbeReliabilityHistory() {
        probeReliabilitySamples = probeReliabilityHistoryStore.load()
        refreshRoutePreview()
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
        guard !profiles.isEmpty else {
            message = "Import an AmneziaWG .conf profile to start."
            return
        }

        let currentProfiles = profiles
        let activeID = activeProfile?.id
        var probes = await directProviderProbes()

        for profile in currentProfiles {
            guard let endpoint = endpoint(for: profile) else {
                continue
            }

            let tcp = await ConnectivityProbeRunner.tcpConnect(host: endpoint.host, port: endpoint.port)
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

            if profile.id == activeID {
                probes.append(ConnectivityProbeResult(
                    targetID: "active-endpoint",
                    targetKind: .vpnServer,
                    serverID: profile.id,
                    region: RegionCode(profile.regionCode ?? "ZZ"),
                    method: .tcpConnect,
                    succeeded: tcp.succeeded,
                    latencyMilliseconds: tcp.latency,
                    packetLoss: tcp.succeeded ? 0 : 1
                ))
            }
        }

        if vpnStatus.isConnectedOrConnecting, let activeID {
            probes.append(contentsOf: await vpnProtectedProbes(serverID: activeID))
        }

        liveProbeResults = probes
        tunnelDiagnostic = tunnelDiagnosticsStore.load()
        recordProbeReliabilitySamples(probes)
        lastProbeDate = Date()
        refreshRoutePreview()
        await applyAutomaticFailoverIfNeeded()
    }

    private func directProviderProbes() async -> [ConnectivityProbeResult] {
        let targets: [(String, ProbeTargetKind, ProbeMethod, () async -> (succeeded: Bool, latency: Double?))] = [
            ("ru-ya", .directEndpoint, .httpHead, { await ConnectivityProbeRunner.httpHead(url: URL(string: "https://ya.ru")!) }),
            ("ru-mos", .directEndpoint, .httpHead, { await ConnectivityProbeRunner.httpHead(url: URL(string: "https://www.mos.ru")!) }),
            ("provider-dns-tcp", .dnsResolver, .tcpConnect, { await ConnectivityProbeRunner.tcpConnect(host: "77.88.8.8", port: 53, timeout: 3) })
        ]

        var probes: [ConnectivityProbeResult] = []
        for target in targets {
            let result = await target.3()
            probes.append(ConnectivityProbeResult(
                targetID: target.0,
                targetKind: target.1,
                method: target.2,
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
            ("foreign-apple-success", .httpHead, { await ConnectivityProbeRunner.httpHead(url: URL(string: "https://www.apple.com/library/test/success.html")!) }),
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

    private func applyAutomaticFailoverIfNeeded() async {
        guard automaticFailoverEnabled, vpnStatus.isConnectedOrConnecting else {
            return
        }

        if let lastAutomaticFailoverDate,
           Date().timeIntervalSince(lastAutomaticFailoverDate) < 90 {
            return
        }

        guard case .switchServer(_, let to, let reason) = healthAssessment.recommendedAction,
              profiles.contains(where: { $0.id == to }),
              to != activeProfile?.id else {
            return
        }

        let oldProfile = activeProfile?.displayName ?? "profile"
        do {
            try profileStore.setActiveProfile(id: to)
            reloadProfiles()
            lastAutomaticFailoverDate = Date()
            notifyFailover(from: oldProfile, to: activeProfile?.displayName ?? "profile", reason: reason)
            suppressExpectedDisconnectNotification = true
            disconnect()
            try? await Task.sleep(for: .seconds(2))
            connect()
        } catch {
            message = "Could not switch profile: \(error.localizedDescription)"
        }
    }

    private func notifyFailover(from oldProfile: String, to newProfile: String, reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "Real Ai VPN switched profile"
        content.body = "\(oldProfile) → \(newProfile). \(reason)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "real-ai-vpn-failover-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func endpoint(for profile: StoredAmneziaConfigProfile) -> ProfileEndpoint? {
        if profile.kind == .singBoxVLESSReality,
           let shadowrocket = try? shadowrocketParser.parse(profile.config) {
            return ProfileEndpoint(host: shadowrocket.host, port: shadowrocket.port)
        }

        guard let decoded = try? decoder.decodeImportedWireGuardConfig(from: profile.config) else {
            return profile.endpointHost.map { ProfileEndpoint(host: $0, port: 51820) }
        }

        return endpoint(from: decoded.endpoint)
    }

    private func endpoint(from rawEndpoint: String) -> ProfileEndpoint? {
        let trimmed = rawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
            let parts = trimmed.split(separator: "]", maxSplits: 1).map(String.init)
            guard let host = parts.first?.dropFirst(),
                  let portPart = parts.last?.dropFirst().split(separator: ":").last,
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

    private static func endpointHost(from endpoint: String) -> String? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["),
           let closingBracket = trimmed.firstIndex(of: "]") {
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<closingBracket])
        }

        return trimmed.split(separator: ":", maxSplits: 1).first.map(String.init)
    }

    private static func regionCode(from displayName: String, endpointHost: String?) -> String? {
        let nameCandidate = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if nameCandidate.count == 2, nameCandidate.allSatisfy(\.isLetter) {
            return nameCandidate
        }

        return endpointHost?
            .split(separator: ".")
            .reversed()
            .first { $0.count == 2 && $0.allSatisfy(\.isLetter) }
            .map { String($0).uppercased() }
    }

    private static func importErrorMessage(for error: Error, rawConfig: String) -> String {
        if rawConfig.localizedCaseInsensitiveContains("\"type\"")
            && rawConfig.localizedCaseInsensitiveContains("VLESS") {
            return "Shadowrocket VLESS/Reality JSON was detected, but it could not be parsed: \(error.localizedDescription)"
        }

        return "Could not import profile: \(error.localizedDescription)"
    }

    private static func routeTitle(
        for decision: RouteDecision,
        activeProfile: StoredAmneziaConfigProfile?,
        status: VPNConnectionStatus
    ) -> String {
        if status == .connected, let activeProfile {
            return "VPN \(activeProfile.regionCode ?? activeProfile.displayName)"
        }

        switch decision.action {
        case .directProviderDNS:
            return "Direct Provider DNS"
        case .vpn(_, let region):
            return "VPN \(region.rawValue)"
        case .ask:
            return "Needs Profile"
        }
    }
}

struct iOSDashboardView: View {
    @ObservedObject var model: iOSDashboardModel
    @State private var importingProfile = false
    @State private var forceVPNException = ""
    @State private var bypassVPNException = ""

    private var buildLabel: String {
        Bundle.main.object(forInfoDictionaryKey: "RAIVPNBuildLabel") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "dev"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    routeCard
                    profileList
                    routingExceptionsCard
                    healthAndRecoveryCard
                    statusCard
                }
                .padding(18)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .fileImporter(
                isPresented: $importingProfile,
                allowedContentTypes: [.plainText, .json, .url, .data],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else {
                    return
                }
                model.importProfile(from: url)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppIconImage()
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("Real Ai VPN")
                    .font(.largeTitle.bold())
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text("v\(buildLabel)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                importingProfile = true
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.title3.weight(.semibold))
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.primaryText)
            .background(.white.opacity(0.08), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1))
            .accessibilityLabel("Import Profile")
        }
        .padding(.top, 8)
    }

    private var routeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Route", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer()
                Text("\(model.confidence)%")
                    .font(.headline)
                    .foregroundStyle(AppTheme.accent)
            }
            Text(model.confidenceDetail)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)

            Text(model.routeTitle)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.primaryText)

            HStack {
                Label("Current RU", systemImage: "location.fill")
                Label("Home IL", systemImage: "house.fill")
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(AppTheme.accent)

            Button {
                NSLog("RealAiVPN iOS main connect button tapped connectedOrConnecting=%@",
                      model.isConnectedOrConnecting ? "true" : "false")
                model.isConnectedOrConnecting ? model.disconnect() : model.connect()
            } label: {
                Label(
                    model.isConnectedOrConnecting ? "Disconnect" : "Connect",
                    systemImage: model.isConnectedOrConnecting ? "stop.fill" : "power"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isConnectedOrConnecting ? .red : AppTheme.accent)
        }
        .padding(18)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var profileList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Imported Profiles", systemImage: "server.rack")
                .font(.headline)
                .foregroundStyle(AppTheme.secondaryText)

            if model.profiles.isEmpty {
                Text("No imported .conf profiles yet.")
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 20)
            } else {
                ForEach(model.profiles) { profile in
                    HStack(spacing: 10) {
                        Button {
                            NSLog("RealAiVPN iOS profile row tapped id=%@ name=%@ kind=%@ endpoint=%@",
                                  profile.id,
                                  profile.displayName,
                                  profile.kind.rawValue,
                                  profile.endpointHost ?? "unknown")
                            model.setActiveProfile(id: profile.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: model.activeProfile?.id == profile.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(AppTheme.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.displayName)
                                        .font(.headline)
                                        .foregroundStyle(AppTheme.primaryText)
                                    Text("\(profile.regionCode ?? "Unknown") · \(profile.endpointHost ?? "endpoint hidden")")
                                        .font(.subheadline)
                                        .foregroundStyle(AppTheme.secondaryText)
                                }
                                Spacer()
                                Text(profile.kind.rawValue)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(AppTheme.accent)
                            }
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            model.deleteProfile(id: profile.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.callout.weight(.bold))
                                .frame(width: 42, height: 42)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Delete \(profile.displayName)")
                    }
                    .padding(14)
                    .background(AppTheme.row, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .padding(18)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var healthAndRecoveryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Health & Recovery", systemImage: "waveform.path.ecg")
                .font(.headline)
                .foregroundStyle(AppTheme.secondaryText)

            HStack(spacing: 12) {
                healthPill(title: "Provider", report: model.healthAssessment.directPath)
                healthPill(title: "Tunnel", report: model.healthAssessment.vpnPath)
            }

            Toggle("Auto-switch degraded VPN", isOn: $model.automaticFailoverEnabled)
                .font(.callout.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText)
                .tint(AppTheme.accent)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.recoveryTitle)
                    .font(.title3.bold())
                    .foregroundStyle(AppTheme.primaryText)
                Text(model.recoveryDetail)
                    .font(.callout)
                    .foregroundStyle(AppTheme.secondaryText)
                Text(model.probeReliabilityDetail)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func healthPill(title: String, report: PathHealthReport) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText)
            Text(report.state.rawValue.capitalized)
                .font(.caption.weight(.bold))
                .foregroundStyle(color(for: report.state))
            Text("\(Int((report.successRate * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppTheme.row, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func color(for state: PathHealthState) -> Color {
        switch state {
        case .healthy:
            return AppTheme.success
        case .degraded:
            return AppTheme.warning
        case .stalled, .down:
            return .red
        }
    }

    private var routingExceptionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Routing Exceptions", systemImage: "arrow.triangle.branch")
                .font(.headline)
                .foregroundStyle(AppTheme.secondaryText)

            Text("Exact domains, IPs, or CIDR ranges. Changes apply on the next reconnect.")
                .font(.footnote)
                .foregroundStyle(AppTheme.secondaryText)

            exceptionInput(
                title: "Через VPN",
                placeholder: "example.ru",
                text: $forceVPNException,
                mode: .forceVPN
            )

            exceptionInput(
                title: "Без VPN",
                placeholder: "mos.ru",
                text: $bypassVPNException,
                mode: .bypassVPN
            )

            if model.routingExceptions.rules.isEmpty {
                Text("No routing exceptions yet.")
                    .font(.callout)
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } else {
                VStack(spacing: 10) {
                    ForEach(model.routingExceptions.rules) { rule in
                        routingExceptionRow(rule)
                    }
                }
            }
        }
        .padding(18)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func exceptionInput(
        title: String,
        placeholder: String,
        text: Binding<String>,
        mode: RoutingExceptionMode
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(mode == .forceVPN ? AppTheme.accent : AppTheme.success)

            HStack(spacing: 10) {
                TextField(placeholder, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(AppTheme.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(AppTheme.row, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    )

                Button {
                    model.addRoutingException(value: text.wrappedValue, mode: mode)
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "plus")
                        .font(.headline.weight(.bold))
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(mode == .forceVPN ? AppTheme.accent : AppTheme.success, in: Circle())
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                .accessibilityLabel("Add \(title)")
            }
        }
    }

    private func routingExceptionRow(_ rule: RoutingExceptionRule) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { model.setRoutingExceptionEnabled(id: rule.id, isEnabled: $0) }
            ))
            .labelsHidden()
            .tint(AppTheme.accent)

            VStack(alignment: .leading, spacing: 4) {
                Text(rule.value)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(rule.mode.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(rule.mode == .forceVPN ? AppTheme.accent : AppTheme.success)
            }

            Spacer()

            Button(role: .destructive) {
                model.deleteRoutingException(id: rule.id)
            } label: {
                Image(systemName: "trash")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.warning)
            .accessibilityLabel("Delete \(rule.value)")
        }
        .padding(12)
        .background(AppTheme.row, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Status", systemImage: "waveform.path.ecg")
                .font(.headline)
                .foregroundStyle(AppTheme.secondaryText)
            Text(model.vpnStatus.rawValue.capitalized)
                .font(.title2.bold())
                .foregroundStyle(AppTheme.primaryText)
            Text(model.message)
                .foregroundStyle(AppTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let provider = model.vpnProviderBundleIdentifier {
                Text(provider)
                    .font(.caption.monospaced())
                    .foregroundStyle(AppTheme.secondaryText.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let diagnostic = model.tunnelDiagnostic {
                Text("\(diagnostic.stage): \(diagnostic.message)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.warning)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct AppIconImage: View {
    var body: some View {
        if UIImage(named: "IconApp") != nil {
            Image("IconApp")
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Image(systemName: "lock.shield.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(AppTheme.accent)
        }
    }
}

private enum AppTheme {
    static let background = LinearGradient(
        colors: [
            Color(red: 0.08, green: 0.11, blue: 0.15),
            Color(red: 0.13, green: 0.12, blue: 0.17)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let card = Color.white.opacity(0.12)
    static let row = Color.white.opacity(0.08)
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.72)
    static let accent = Color(red: 0.27, green: 0.76, blue: 0.82)
    static let success = Color(red: 0.34, green: 0.82, blue: 0.62)
    static let warning = Color(red: 1.0, green: 0.58, blue: 0.26)
}
