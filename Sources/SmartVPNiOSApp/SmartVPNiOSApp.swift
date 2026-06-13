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

private var iOSBuildLabel: String {
    Bundle.main.object(forInfoDictionaryKey: "RAIVPNBuildLabel") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "dev"
}

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

    static func httpGet(url: URL, headers: [String: String] = [:], timeout: TimeInterval = 5) async -> (succeeded: Bool, latency: Double?) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
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

private struct StoredProfileQualityHistory: Codable {
    var samples: [ServerQualitySample]
}

private struct StoredProbeReliabilityHistory: Codable {
    var probes: [ConnectivityProbeResult]
}

struct iOSVPNChannelStatistics: Identifiable {
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
    var dailyReport: VPNChannelDailyReport?
    var isActive: Bool
    var isConnected: Bool

    var coreMLScore: Double {
        dailyReport?.channelScore ?? ranking?.score ?? successRate
    }

    var coreMLRisk: Double? {
        dailyReport?.degradationRisk
    }

    var coreMLConfidence: Double {
        dailyReport?.confidence ?? ranking?.confidence ?? 0
    }

    var coreMLAction: CoreMLRecommendedActionHint? {
        dailyReport?.recommendedActionHint
    }

    var coreMLSummary: String {
        dailyReport?.summaryText ?? ranking?.reason ?? "CoreML is waiting for more channel data."
    }

    var coreMLEvidenceCount: Int {
        (dailyReport?.sampleCount ?? sampleCount) + (dailyReport?.probeCount ?? 0)
    }
}

private struct LocalProfileQualityHistoryStore {
    private let key = "ios.profileQualityHistory.v1"
    private let featureExtractor = CoreMLServerFeatureExtractor()

    func load() -> [ServerQualitySample] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let history = try? JSONDecoder().decode(StoredProfileQualityHistory.self, from: data) else {
            return []
        }

        return featureExtractor.trimToHistoryWindow(history.samples)
    }

    func save(_ samples: [ServerQualitySample]) {
        let history = StoredProfileQualityHistory(samples: featureExtractor.trimToHistoryWindow(samples))
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
    @Published private(set) var connectedProfileID: String?
    @Published private(set) var observedExitIP: String?
    @Published private(set) var observedExitCountry: String?
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
            healthScore: 1,
            successRate: 1,
            averageLatencyMilliseconds: nil,
            averagePacketLoss: 0,
            consecutiveFailures: 0,
            reason: "collecting"
        ),
        vpnPath: PathHealthReport(
            state: .down,
            healthScore: 0,
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
    @Published private(set) var lastRecoveryDecisionLog = ""
    @Published var automaticFailoverEnabled = UserDefaults.standard.object(forKey: "ios.automaticFailoverEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automaticFailoverEnabled, forKey: "ios.automaticFailoverEnabled")
        }
    }
    @Published var connectOnStartEnabled = UserDefaults.standard.object(forKey: "ios.connectOnStartEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(connectOnStartEnabled, forKey: "ios.connectOnStartEnabled")
            Task { await vpnManager.prepareProfile(configuration: vpnConfiguration) }
        }
    }
    @Published var reconnectAfterDropEnabled = UserDefaults.standard.object(forKey: "ios.reconnectAfterDropEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(reconnectAfterDropEnabled, forKey: "ios.reconnectAfterDropEnabled")
            Task { await vpnManager.prepareProfile(configuration: vpnConfiguration) }
        }
    }
    @Published var killSwitchEnabled = UserDefaults.standard.object(forKey: "ios.killSwitchEnabled") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(killSwitchEnabled, forKey: "ios.killSwitchEnabled")
        }
    }
    @Published var dnsProtectionEnabled = UserDefaults.standard.object(forKey: "ios.dnsProtectionEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(dnsProtectionEnabled, forKey: "ios.dnsProtectionEnabled")
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
    private var vpnHardDegradedSince: Date?
    private var profileQuarantineUntil: [String: Date] = [:]
    private var suppressExpectedDisconnectNotification = false
    private var dropRecoveryTask: Task<Void, Never>?
    private var dropRecoveryProfileID: String?
    private var dropRecoveryAttempt = 0
    private var dropRecoveryAttemptCounts: [String: Int] = [:]
    private var dropRecoveryConnectedAt: [String: Date] = [:]
    private let maxDropReconnectAttempts = 5
    private let dropReconnectDelaySeconds: UInt64 = 2
    private let stableConnectionResetSeconds: TimeInterval = 60

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
                guard let self else {
                    return
                }
                self.vpnLastError = self.vpnStatus == .connected ? nil : error
                self.refreshStatusMessage()
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
            await connectOnStartIfNeeded()
        }
    }

    deinit {
        monitoringTask?.cancel()
        dropRecoveryTask?.cancel()
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

    var connectedProfile: StoredAmneziaConfigProfile? {
        guard let connectedProfileID else {
            return nil
        }
        return profiles.first { $0.id == connectedProfileID }
    }

    var displayedProfile: StoredAmneziaConfigProfile? {
        vpnStatus.isConnectedOrConnecting ? (connectedProfile ?? activeProfile) : activeProfile
    }

    var confidenceDetail: String {
        guard let lastProbeDate else {
            return "collecting live probes"
        }

        let age = max(0, Int(Date().timeIntervalSince(lastProbeDate)))
        let sampleCount = displayedProfile.map { profile in
            qualitySamples.filter { $0.serverID == profile.id }.count
        } ?? qualitySamples.count
        if let best = displayedProfile.flatMap({ profile in
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
        guard let displayedProfile,
              let best = probeReliabilityAnalyzer.bestSummary(
                from: probeReliabilitySamples,
                serverID: displayedProfile.id,
                targetKind: .vpnProtectedEndpoint
              ) else {
            return "Probe reliability is learning on this profile."
        }

        return "Best check: \(best.targetID) · \(Int((best.reliabilityScore * 100).rounded()))% reliable."
    }

    var context: ServerSelectionContext {
        ServerSelectionContext(
            currentRegion: RegionCode("RU"),
            homeRegion: RegionCode("IL"),
            networkKind: .wifi,
            providerASN: nil,
            hourOfDay: Calendar.current.component(.hour, from: Date()),
            previousServerID: activeProfileID
        )
    }

    var channelStatistics: [iOSVPNChannelStatistics] {
        let dailyReportsByServerID = VPNChannelDailyReportBuilder().reports(
            for: effectiveServers,
            context: context,
            samples: qualitySamples,
            probeHistory: probeReliabilitySamples,
            rankedServers: rankedServers
        ).reduce(into: [String: VPNChannelDailyReport]()) { reports, report in
            reports[report.serverID] = report
        }

        return effectiveServers.map { server in
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
            let activeID = displayedProfile?.id ?? activeProfile?.id
            let connectedID = connectedProfile?.id

            return iOSVPNChannelStatistics(
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
                dailyReport: dailyReportsByServerID[server.id],
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

        guard displayedProfile?.kind == .singBoxVLESSReality else {
            return "Profile DNS only · split-dns-provider-lane unavailable for AWG"
        }

        return "Provider DNS lane: Yandex DNS"
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

    func importProfileFromPastedText(displayName: String, rawConfig: String) {
        let trimmedConfig = rawConfig.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConfig.isEmpty else {
            message = "Paste a key, URL, JSON, or raw config first."
            return
        }

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await importProfile(
                displayName: trimmedName.isEmpty ? "Pasted Profile" : trimmedName,
                rawConfig: trimmedConfig
            )
        }
    }

    func reportStatus(_ status: String) {
        message = status
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
        cancelDropRecovery()
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

    func reconnectProfile(id: String) {
        cancelDropRecovery()
        NSLog("RealAiVPN iOS reconnectProfile id=%@", id)
        let wasConnectedOrConnecting = vpnStatus.isConnectedOrConnecting
        do {
            try profileStore.setActiveProfile(id: id)
            reloadProfiles()
            guard let selected = activeProfile else {
                message = "Could not reconnect: profile is missing."
                return
            }
            message = wasConnectedOrConnecting
                ? "Reconnecting \(selected.displayName)..."
                : "Connecting \(selected.displayName)..."
            if wasConnectedOrConnecting {
                suppressExpectedDisconnectNotification = true
                message = killSwitchEnabled
                    ? "Reconnecting \(selected.displayName) with Kill Switch..."
                    : "Reconnecting \(selected.displayName)..."
                vpnManager.disconnect()
                Task {
                    await waitUntilVPNIsDisconnected()
                    connect()
                }
            } else {
                connect()
            }
        } catch {
            NSLog("RealAiVPN iOS reconnectProfile failed: %@", error.localizedDescription)
            message = "Could not reconnect profile: \(error.localizedDescription)"
        }
    }

    func reconnectVPNWithKillSwitch() {
        cancelDropRecovery()
        guard vpnStatus != .connecting, vpnStatus != .disconnecting else {
            return
        }
        guard let activeProfile else {
            message = "Import an AmneziaWG .conf profile first."
            return
        }

        killSwitchEnabled = true
        message = vpnStatus.isConnectedOrConnecting
            ? "Reconnecting \(activeProfile.displayName) with Kill Switch..."
            : "Connecting \(activeProfile.displayName) with Kill Switch..."

        if vpnStatus.isConnectedOrConnecting {
            suppressExpectedDisconnectNotification = true
            vpnManager.disconnect()
            Task {
                await waitUntilVPNIsDisconnected()
                connect()
            }
        } else {
            connect()
        }
    }

    func deleteProfile(id: String) {
        let wasConnected = vpnStatus.isConnectedOrConnecting
        let deletingActiveProfile = activeProfile?.id == id
        let deletingConnectedProfile = connectedProfile?.id == id
        let deletedName = profiles.first { $0.id == id }?.displayName ?? "profile"

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
            if profiles.isEmpty {
                if wasConnected {
                    suppressExpectedDisconnectNotification = true
                    vpnManager.disconnect()
                }
                connectedProfileID = nil
                message = "Deleted \(deletedName). Import a profile to connect."
            } else if wasConnected, deletingActiveProfile || deletingConnectedProfile {
                connectedProfileID = nil
                suppressExpectedDisconnectNotification = true
                vpnManager.disconnect()
                Task {
                    await waitUntilVPNIsDisconnected()
                    connect()
                }
                message = "Deleted \(deletedName). Reconnecting \(activeProfile?.displayName ?? "profile")."
            } else {
                message = "Deleted \(deletedName). Active profile is \(activeProfile?.displayName ?? "profile")."
            }
        } catch {
            message = "Could not delete \(deletedName): \(error.localizedDescription)"
        }
    }

    func renameProfile(id: String, displayName: String) {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            message = "Profile name cannot be empty."
            return
        }

        do {
            try profileStore.renameProfile(id: id, displayName: trimmedName)
            reloadProfiles()
            message = "Renamed profile to \(trimmedName)."
        } catch {
            message = "Could not rename profile: \(error.localizedDescription)"
        }
    }

    func connect() {
        if dropRecoveryTask == nil {
            cancelDropRecovery()
        }
        NSLog("RealAiVPN iOS connect() entered connectedOrConnecting=%@", isConnectedOrConnecting ? "true" : "false")
        guard let activeProfile else {
            NSLog("RealAiVPN iOS connect() no active profile")
            message = "Import an AmneziaWG .conf profile first."
            return
        }

        Task {
            let connectProfile = await resolveProfileForConnect(activeProfile)
            connectedProfileID = connectProfile.id
            observedExitIP = nil
            observedExitCountry = nil
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
        cancelDropRecovery()
        NSLog("RealAiVPN iOS disconnect() entered")
        suppressExpectedDisconnectNotification = true
        message = "Disconnecting..."
        Task {
            await vpnManager.disconnectDisablingOnDemand()
        }
    }

    private func connectOnStartIfNeeded() async {
        guard connectOnStartEnabled else {
            return
        }

        try? await Task.sleep(for: .seconds(1))
        guard !vpnStatus.isConnectedOrConnecting, activeProfile != nil else {
            return
        }

        message = "Connecting VPN on app start..."
        connect()
    }

    private func cancelDropRecovery() {
        dropRecoveryTask?.cancel()
        clearDropRecoveryState()
        dropRecoveryAttemptCounts.removeAll()
        dropRecoveryConnectedAt.removeAll()
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
              profiles.contains(where: { $0.id == profileID }) else {
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

        for _ in 1...maxDropReconnectAttempts {
            if Task.isCancelled {
                return
            }

            guard let reservedAttempt = reserveDropRecoveryAttempt(for: profileID) else {
                NSLog("RealAiVPN iOS dropRecovery exhausted profileID=%@", profileID)
                await applyDropRecoveryFailover(failedProfileID: profileID, failedProfileName: profileName)
                return
            }

            guard profiles.contains(where: { $0.id == profileID }) else {
                message = "Last VPN failed after 5 attempts. No healthy fallback profile."
                return
            }

            dropRecoveryAttempt = reservedAttempt
            NSLog("RealAiVPN iOS dropRecovery attempt=%ld/%ld profileID=%@",
                  reservedAttempt,
                  maxDropReconnectAttempts,
                  profileID)
            do {
                try profileStore.setActiveProfile(id: profileID)
                reloadProfiles()
            } catch {
                message = "Could not reconnect \(profileName): \(error.localizedDescription)"
                return
            }

            message = "Reconnecting \(profileName) after drop/reset (\(reservedAttempt)/\(maxDropReconnectAttempts))..."
            vpnLastError = nil
            connect()

            if await waitForDropRecoveryConnection(profileID: profileID) {
                message = "Connected to \(profileName)."
                refreshRoutePreview()
                return
            }

            if reservedAttempt < maxDropReconnectAttempts {
                try? await Task.sleep(for: .seconds(dropReconnectDelaySeconds))
            }
        }

        await applyDropRecoveryFailover(failedProfileID: profileID, failedProfileName: profileName)
    }

    private func reserveDropRecoveryAttempt(for profileID: String) -> Int? {
        let usedAttempts = dropRecoveryAttemptCounts[profileID, default: 0]
        guard usedAttempts < maxDropReconnectAttempts else {
            return nil
        }

        let nextAttempt = usedAttempts + 1
        dropRecoveryAttemptCounts[profileID] = nextAttempt
        return nextAttempt
    }

    private func resetDropRecoveryAttemptsIfConnectionWasStable(profileID: String?, now: Date = Date()) {
        guard let profileID,
              let connectedAt = dropRecoveryConnectedAt[profileID] else {
            return
        }

        dropRecoveryConnectedAt[profileID] = nil
        if now.timeIntervalSince(connectedAt) >= stableConnectionResetSeconds {
            dropRecoveryAttemptCounts[profileID] = nil
        }
    }

    private func waitForDropRecoveryConnection(profileID: String, timeoutSeconds: Double = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        repeat {
            if Task.isCancelled {
                return false
            }
            if (vpnStatus == .connected || vpnStatus == .reasserting),
               connectedProfileID == profileID {
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
            message = "Last VPN failed after 5 attempts. Auto-switch is disabled."
            refreshRoutePreview()
            return
        }

        quarantineProfile(id: failedProfileID)
        message = "Switching after failed reconnect attempts..."
        refreshRoutePreview()

        let recommendedID: String?
        if case .switchServer(_, let to, _) = healthAssessment.recommendedAction,
           to != failedProfileID,
           profiles.contains(where: { $0.id == to }) {
            recommendedID = to
        } else {
            recommendedID = rankedServers
                .map(\.server.id)
                .first { id in
                    id != failedProfileID && profiles.contains(where: { $0.id == id })
                }
        }

        guard let recommendedID else {
            message = "Last VPN failed after 5 attempts. No healthy fallback profile."
            refreshRoutePreview()
            return
        }

        do {
            try profileStore.setActiveProfile(id: recommendedID)
            reloadProfiles()
            lastAutomaticFailoverDate = Date()
            notifyFailover(from: failedProfileName, to: activeProfile?.displayName ?? "profile", reason: "drop-reset-retry-exhausted")
            connect()
        } catch {
            message = "Could not switch profile: \(error.localizedDescription)"
            refreshRoutePreview()
        }
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
        let decision = selector.decideRoute(
            destinationRegion: .foreign,
            context: context,
            servers: servers
        )
        rankedServers = selector.rankedServers(context: context, servers: servers)
        if !liveProbeResults.isEmpty {
            healthAssessment = monitor.assess(
                probes: liveProbeResults,
                activeServerID: displayedProfile?.id,
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
        routeTitle = Self.routeTitle(for: decision, activeProfile: displayedProfile, status: vpnStatus)
        if vpnStatus.isConnectedOrConnecting {
            confidence = Int((healthAssessment.vpnPath.healthScore * 100).rounded())
        } else {
            let activeConfidence = displayedProfile
                .flatMap { profile in rankedServers.first { $0.server.id == profile.id }?.confidence }
            confidence = Int(((activeConfidence ?? decision.rankedServers.first?.confidence ?? rankedServers.first?.confidence ?? 0) * 100).rounded())
        }
    }

    private func refreshStatusMessage() {
        let profileName = displayedProfile?.displayName ?? activeProfile?.displayName ?? "profile"
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
        let droppedProfileID = connectedProfileID ?? displayedProfile?.id ?? activeProfile?.id
        let droppedProfileName = displayedProfile?.displayName ?? activeProfile?.displayName ?? "profile"
        vpnStatus = status

        if status == .connected {
            vpnLastError = nil
            tunnelDiagnostic = nil
            if let profileID = connectedProfileID ?? displayedProfile?.id ?? activeProfile?.id {
                dropRecoveryConnectedAt[profileID] = Date()
            }
        }

        guard status == .disconnected else {
            return
        }

        connectedProfileID = nil
        observedExitIP = nil
        observedExitCountry = nil
        tunnelDiagnostic = tunnelDiagnosticsStore.load()
        refreshStatusMessage()

        if suppressExpectedDisconnectNotification {
            suppressExpectedDisconnectNotification = false
            return
        }

        if previousStatus == .connected || previousStatus == .reasserting {
            resetDropRecoveryAttemptsIfConnectionWasStable(profileID: droppedProfileID)
            notifyTunnelDropped(profile: droppedProfileName)
            reconnectAfterUnexpectedDrop(profileID: droppedProfileID, profileName: droppedProfileName)
        }
    }

    private func notifyTunnelDropped(profile: String) {
        let content = UNMutableNotificationContent()
        content.title = "Real Ai Router disconnected"
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
            regionCode: profile?.regionCode ?? "ZZ",
            killSwitchEnabled: killSwitchEnabled,
            dnsProtectionEnabled: dnsProtectionEnabled,
            autoReconnectOnDemandEnabled: false
        )
    }

    private func localizedVPNDescription(for profile: StoredAmneziaConfigProfile?) -> String {
        profile?.kind == .singBoxVLESSReality ? "Real Ai Router VLESS" : "Real Ai Router AWG"
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

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }

        return values.reduce(0, +) / Double(values.count)
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
        qualitySamples = CoreMLServerFeatureExtractor().trimToHistoryWindow(qualitySamples)
        qualityHistoryStore.save(qualitySamples)
    }

    private func recordProbeReliabilitySamples(_ probes: [ConnectivityProbeResult]) {
        probeReliabilitySamples.append(contentsOf: probes)
        probeReliabilitySamples = Array(probeReliabilitySamples.suffix(960))
        probeReliabilityHistoryStore.save(probeReliabilitySamples)
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
        let activeID = displayedProfile?.id
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
            probes.append(await exitIPProbe(serverID: activeID))
            probes.append(await exitCountryProbe(serverID: activeID))
        }

        liveProbeResults = probes
        tunnelDiagnostic = tunnelDiagnosticsStore.load()
        recordProbeReliabilitySamples(probes)
        lastProbeDate = Date()
        refreshRoutePreview()
        await applyAutomaticFailoverIfNeeded()
    }

    private var providerProbeTrust: PathProbeTrust {
        vpnStatus.isConnectedOrConnecting ? .untrustedWhileVPNActive : .trusted
    }

    private func directProviderProbes() async -> [ConnectivityProbeResult] {
        let regional = [
            ("ru-ya", ProbeTargetKind.directEndpoint, ProbeMethod.httpHead, { await ConnectivityProbeRunner.httpHead(url: URL(string: "https://ya.ru")!) }),
            ("ru-mos", ProbeTargetKind.directEndpoint, ProbeMethod.httpHead, { await ConnectivityProbeRunner.httpHead(url: URL(string: "https://www.mos.ru")!) }),
            ("ru-rbc", ProbeTargetKind.directEndpoint, ProbeMethod.httpHead, { await ConnectivityProbeRunner.httpHead(url: URL(string: "https://www.rbc.ru")!) }),
            ("ru-gosuslugi", ProbeTargetKind.directEndpoint, ProbeMethod.httpHead, { await ConnectivityProbeRunner.httpHead(url: URL(string: "https://www.gosuslugi.ru")!) })
        ]
        let targets: [(String, ProbeTargetKind, ProbeMethod, () async -> (succeeded: Bool, latency: Double?))] = [
            regional.randomElement()!,
            ("provider-yandex-dns-tcp", .dnsResolver, .tcpConnect, { await ConnectivityProbeRunner.tcpConnect(host: "77.88.8.8", port: 53, timeout: 3) })
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
        let lightweight = [
            ("infra-cloudflare-trace", ProbeTargetKind.vpnProtectedEndpoint, ProbeMethod.httpGet, { await ConnectivityProbeRunner.httpGet(url: URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!) }),
            ("infra-oneoneoneone-trace", ProbeTargetKind.vpnProtectedEndpoint, ProbeMethod.httpGet, { await ConnectivityProbeRunner.httpGet(url: URL(string: "https://1.1.1.1/cdn-cgi/trace")!) }),
            ("infra-example", ProbeTargetKind.vpnProtectedEndpoint, ProbeMethod.httpHead, { await ConnectivityProbeRunner.httpHead(url: URL(string: "https://example.com")!) }),
            ("infra-iana", ProbeTargetKind.vpnProtectedEndpoint, ProbeMethod.httpHead, { await ConnectivityProbeRunner.httpHead(url: URL(string: "https://www.iana.org")!) })
        ]
        let publicWeb = [
            ("public-wikipedia", ProbeTargetKind.vpnProtectedEndpoint, ProbeMethod.httpHead, { await ConnectivityProbeRunner.httpHead(url: URL(string: "https://www.wikipedia.org")!) }),
            ("public-bing", ProbeTargetKind.vpnProtectedEndpoint, ProbeMethod.httpHead, { await ConnectivityProbeRunner.httpHead(url: URL(string: "https://www.bing.com")!) }),
            ("public-duckduckgo", ProbeTargetKind.vpnProtectedEndpoint, ProbeMethod.httpHead, { await ConnectivityProbeRunner.httpHead(url: URL(string: "https://duckduckgo.com")!) }),
            ("public-mozilla", ProbeTargetKind.vpnProtectedEndpoint, ProbeMethod.httpHead, { await ConnectivityProbeRunner.httpHead(url: URL(string: "https://www.mozilla.org")!) }),
            ("public-debian", ProbeTargetKind.vpnProtectedEndpoint, ProbeMethod.httpHead, { await ConnectivityProbeRunner.httpHead(url: URL(string: "https://www.debian.org")!) }),
            ("public-kernel", ProbeTargetKind.vpnProtectedEndpoint, ProbeMethod.httpHead, { await ConnectivityProbeRunner.httpHead(url: URL(string: "https://www.kernel.org")!) })
        ]
        let regional = [
            ("regional-ya", ProbeTargetKind.vpnProtectedEndpoint, ProbeMethod.httpHead, { await ConnectivityProbeRunner.httpHead(url: URL(string: "https://ya.ru")!) }),
            ("regional-mos", ProbeTargetKind.vpnProtectedEndpoint, ProbeMethod.httpHead, { await ConnectivityProbeRunner.httpHead(url: URL(string: "https://www.mos.ru")!) }),
            ("regional-rbc", ProbeTargetKind.vpnProtectedEndpoint, ProbeMethod.httpHead, { await ConnectivityProbeRunner.httpHead(url: URL(string: "https://www.rbc.ru")!) }),
            ("regional-gosuslugi", ProbeTargetKind.vpnProtectedEndpoint, ProbeMethod.httpHead, { await ConnectivityProbeRunner.httpHead(url: URL(string: "https://www.gosuslugi.ru")!) })
        ]
        let tcp = [
            ("tcp-cloudflare-443", ProbeTargetKind.vpnProtectedEndpoint, ProbeMethod.tcpConnect, { await ConnectivityProbeRunner.tcpConnect(host: "1.1.1.1", port: 443, timeout: 3) }),
            ("tcp-quad9-443", ProbeTargetKind.vpnProtectedEndpoint, ProbeMethod.tcpConnect, { await ConnectivityProbeRunner.tcpConnect(host: "9.9.9.9", port: 443, timeout: 3) }),
            ("tcp-opendns-443", ProbeTargetKind.vpnProtectedEndpoint, ProbeMethod.tcpConnect, { await ConnectivityProbeRunner.tcpConnect(host: "208.67.222.222", port: 443, timeout: 3) })
        ]
        let doh = [
            ("doh-cloudflare-ya", ProbeTargetKind.dnsResolver, ProbeMethod.dnsQuery, { await ConnectivityProbeRunner.httpGet(url: URL(string: "https://cloudflare-dns.com/dns-query?name=ya.ru&type=A")!, headers: ["Accept": "application/dns-json"]) }),
            ("doh-quad9-ya", ProbeTargetKind.dnsResolver, ProbeMethod.dnsQuery, { await ConnectivityProbeRunner.httpGet(url: URL(string: "https://dns.quad9.net/dns-query?name=ya.ru&type=A")!, headers: ["Accept": "application/dns-json"]) })
        ]
        let targets: [(String, ProbeTargetKind, ProbeMethod, () async -> (succeeded: Bool, latency: Double?))] = [
            lightweight.randomElement()!,
            publicWeb.randomElement()!,
            regional.randomElement()!,
            tcp.randomElement()!,
            doh.randomElement()!
        ]

        var probes: [ConnectivityProbeResult] = []
        for target in targets {
            let result = await target.3()
            probes.append(ConnectivityProbeResult(
                targetID: target.0,
                targetKind: target.1,
                serverID: serverID,
                method: target.2,
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
              to != displayedProfile?.id else {
            return
        }

        let oldProfile = activeProfile?.displayName ?? "profile"
        do {
            if let from = displayedProfile?.id {
                quarantineProfile(id: from)
            }
            try profileStore.setActiveProfile(id: to)
            reloadProfiles()
            lastAutomaticFailoverDate = Date()
            notifyFailover(from: oldProfile, to: activeProfile?.displayName ?? "profile", reason: reason)
            suppressExpectedDisconnectNotification = true
            message = killSwitchEnabled ? "Switching VPN with Kill Switch..." : "Switching VPN..."
            vpnManager.disconnect()
            await waitUntilVPNIsDisconnected()
            connect()
        } catch {
            message = "Could not switch profile: \(error.localizedDescription)"
        }
    }

    private func notifyFailover(from oldProfile: String, to newProfile: String, reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "Real Ai Router switched profile"
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

private enum iOSMainTab: Hashable {
    case home
    case profiles
    case route
    case settings
    case statistics
}

struct iOSDashboardView: View {
    @ObservedObject var model: iOSDashboardModel
    @State private var selectedTab: iOSMainTab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                iOSHomeScreen(model: model) {
                    selectedTab = .route
                } openProfiles: {
                    selectedTab = .profiles
                }
            }
            .tabItem {
                Label("Home", systemImage: "house.fill")
            }
            .tag(iOSMainTab.home)

            NavigationStack {
                iOSProfilesScreen(model: model)
            }
            .tabItem {
                Label("Profiles", systemImage: "person.2.fill")
            }
            .tag(iOSMainTab.profiles)

            NavigationStack {
                iOSRoutingExceptionsScreen(model: model)
            }
            .tabItem {
                Label("Route", systemImage: "arrow.triangle.swap")
            }
            .tag(iOSMainTab.route)

            NavigationStack {
                iOSSettingsScreen(model: model)
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .tag(iOSMainTab.settings)

            NavigationStack {
                iOSStatisticsScreen(model: model)
            }
            .tabItem {
                Label("Stat", systemImage: "chart.line.uptrend.xyaxis")
            }
            .tag(iOSMainTab.statistics)
        }
        .tint(AppTheme.accent)
        .background(AppTheme.background.ignoresSafeArea())
    }
}

private struct iOSHomeScreen: View {
    @ObservedObject var model: iOSDashboardModel
    let openRoute: () -> Void
    let openProfiles: () -> Void

    private var activeProfile: StoredAmneziaConfigProfile? {
        model.displayedProfile ?? model.activeProfile
    }

    private var statusTitle: String {
        model.isConnectedOrConnecting ? "Connected" : "Disconnected"
    }

    private var locationTitle: String {
        guard let profile = activeProfile else {
            return "No profile"
        }
        let region = profile.regionCode ?? "ZZ"
        return "\(profile.displayName) · \(region)"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                heroCard
                healthCard
                routeSummaryCard
                profilesPreviewCard
                statusCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppIconImage()
                .frame(width: 60, height: 60)

            VStack(alignment: .leading, spacing: 4) {
                Text("Real Ai Router")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("v\(iOSBuildLabel)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            NavigationLink {
                iOSProfilesScreen(model: model)
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(width: 54, height: 54)
                    .background(AppTheme.floatingButton, in: Circle())
                    .overlay(Circle().stroke(AppTheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Import profile")
        }
    }

    private var heroCard: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(AppTheme.accent.opacity(0.20), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: max(0.02, CGFloat(model.confidence) / 100))
                    .stroke(
                        AppTheme.accent,
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Image(systemName: model.isConnectedOrConnecting ? "checkmark.shield.fill" : "shield.fill")
                    .font(.system(size: 50, weight: .bold))
                    .foregroundStyle(model.isConnectedOrConnecting ? AppTheme.accent : AppTheme.secondaryText)
            }
            .frame(width: 168, height: 168)
            .padding(.top, 8)

            VStack(spacing: 7) {
                Text(statusTitle)
                    .font(.title.bold())
                    .foregroundStyle(AppTheme.primaryText)
                Text(locationTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text("\(model.confidence)% confidence")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AppTheme.accent)
            }

            metricsGrid

            Button {
                model.isConnectedOrConnecting ? model.disconnect() : model.connect()
            } label: {
                Label(
                    model.isConnectedOrConnecting ? "Disconnect" : "Connect",
                    systemImage: model.isConnectedOrConnecting ? "stop.fill" : "power"
                )
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.isConnectedOrConnecting ? .red : .white)
            .background(
                model.isConnectedOrConnecting
                    ? Color.red.opacity(0.10)
                    : AppTheme.accent,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .padding(16)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
        .shadow(color: AppTheme.shadow, radius: 22, x: 0, y: 14)
    }

    private var metricsGrid: some View {
        HStack(spacing: 0) {
            metric(title: "Latency", value: latencyText)
            Divider().opacity(0.35)
            metric(title: "Packet Loss", value: packetLossText)
            Divider().opacity(0.35)
            metric(title: "Last Check", value: lastCheckText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func metric(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.primaryText)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection Health")
                .font(.title3.bold())
                .foregroundStyle(AppTheme.primaryText)

            healthRow(title: "Provider", report: model.healthAssessment.directPath)
            healthRow(title: "Tunnel", report: model.healthAssessment.vpnPath)
            HStack {
                statusDot(color: AppTheme.accent)
                Text("Auto Recovery")
                    .font(.headline)
                    .foregroundStyle(AppTheme.primaryText)
                Spacer()
                Text(model.automaticFailoverEnabled ? "Ready" : "Off")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(model.automaticFailoverEnabled ? AppTheme.accent : AppTheme.secondaryText)
            }
            .padding(13)
            .background(AppTheme.row, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(model.dnsPolicyDiagnostic)
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(2)

            Label("All systems operational", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(AppTheme.success)
                .padding(.top, 4)
        }
        .padding(16)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
        .shadow(color: AppTheme.shadow, radius: 18, x: 0, y: 10)
    }

    private func healthRow(title: String, report: PathHealthReport) -> some View {
        HStack {
            statusDot(color: color(for: report.state))
            Text(title)
                .font(.headline)
                .foregroundStyle(AppTheme.primaryText)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(report.state.rawValue.capitalized)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(color(for: report.state))
                Text("\(Int((report.successRate * 100).rounded()))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .padding(13)
        .background(AppTheme.row, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func statusDot(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }

    private var routeSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Current Route")
                .font(.title3.bold())
                .foregroundStyle(AppTheme.primaryText)
            routeLine("Current Region", "RU - Russia")
            routeLine("Home Region", "IL - Israel")
            routeLine("Exit Location", exitLocationText)
            Divider()
            Button(action: openRoute) {
                HStack {
                    Text("Details")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.headline)
                .foregroundStyle(AppTheme.primaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }

    private func routeLine(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
            Spacer()
            Text(value)
                .font(.callout.weight(.bold))
                .foregroundStyle(AppTheme.primaryText)
                .multilineTextAlignment(.trailing)
        }
    }

    private var profilesPreviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("VPN Profiles")
                    .font(.title3.bold())
                    .foregroundStyle(AppTheme.primaryText)
                Spacer()
                Button(action: openProfiles) {
                    Image(systemName: "plus")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppTheme.accent)
                }
                .buttonStyle(.plain)
            }

            ForEach(Array(model.profiles.prefix(3))) { profile in
                Button {
                    model.setActiveProfile(id: profile.id)
                } label: {
                    HStack(spacing: 10) {
                        Text(flag(for: profile.regionCode))
                        Text(profile.displayName)
                            .font(.headline)
                            .foregroundStyle(AppTheme.primaryText)
                            .lineLimit(1)
                        Spacer()
                        Text(profile.id == model.activeProfile?.id ? "Active" : "Standby")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(profile.id == model.activeProfile?.id ? AppTheme.success : AppTheme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(AppTheme.pill, in: Capsule())
                    }
                }
                .buttonStyle(.plain)
            }

            Divider()

            Button(action: openProfiles) {
                HStack {
                    Text("View All Profiles")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.headline)
                .foregroundStyle(AppTheme.primaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Status", systemImage: "waveform.path.ecg")
                .font(.headline)
                .foregroundStyle(AppTheme.secondaryText)
            Text(model.vpnStatus.rawValue.capitalized)
                .font(.title2.bold())
                .foregroundStyle(AppTheme.primaryText)
            Text(model.message)
                .font(.callout)
                .foregroundStyle(AppTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let diagnostic = model.tunnelDiagnostic {
                Text("\(diagnostic.stage): \(diagnostic.message)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.warning)
                    .lineLimit(4)
            }
        }
        .padding(16)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }

    private var latencyText: String {
        guard let latency = model.healthAssessment.vpnPath.averageLatencyMilliseconds
            ?? model.healthAssessment.directPath.averageLatencyMilliseconds else {
            return "--"
        }
        return "\(Int(latency.rounded())) ms"
    }

    private var packetLossText: String {
        let loss = model.healthAssessment.vpnPath.averagePacketLoss
        return "\(Int((loss * 100).rounded()))%"
    }

    private var lastCheckText: String {
        guard let lastProbeDate = model.lastProbeDate else {
            return "--"
        }
        return "\(max(0, Int(Date().timeIntervalSince(lastProbeDate))))s ago"
    }

    private var exitLocationText: String {
        let region = activeProfile?.regionCode ?? model.observedExitCountry ?? "ZZ"
        if let exit = model.observedExitIP {
            return "\(region) - \(exit)"
        }
        return region
    }

    private func color(for state: PathHealthState) -> Color {
        switch state {
        case .healthy:
            return AppTheme.success
        case .degradedSoft, .degradedHard:
            return AppTheme.warning
        case .stalled, .down, .connectedButUnusable:
            return .red
        }
    }
}

private struct iOSRouteScreen: View {
    @ObservedObject var model: iOSDashboardModel
    @State private var selectedProfileID: String?

    private var selectedProfile: StoredAmneziaConfigProfile? {
        model.profiles.first { $0.id == selectedProfileID } ?? model.activeProfile
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                routeSummary
                profilePicker
                NavigationLink {
                    iOSRoutingExceptionsScreen(model: model)
                } label: {
                    HStack {
                        Label("Routing Exceptions", systemImage: "arrow.triangle.branch")
                        Spacer()
                        Text("\(model.routingExceptions.rules.count)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(AppTheme.accent)
                        Image(systemName: "chevron.right")
                    }
                    .font(.headline)
                    .foregroundStyle(AppTheme.primaryText)
                    .padding(16)
                    .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    guard let selectedProfile else {
                        return
                    }
                    if model.isConnectedOrConnecting {
                        model.reconnectProfile(id: selectedProfile.id)
                    } else {
                        model.setActiveProfile(id: selectedProfile.id)
                    }
                } label: {
                    Text("Apply Route")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .disabled(selectedProfile == nil)
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Switch Route")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedProfileID = model.activeProfile?.id
        }
    }

    private var routeSummary: some View {
        VStack(spacing: 12) {
            routeLine("Current Region", "RU - Russia")
            routeLine("Home Region", "IL - Israel")
            routeLine("Exit Location", selectedProfile.map { "\($0.regionCode ?? "ZZ") - \($0.displayName)" } ?? "No profile")
        }
        .padding(16)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }

    private func routeLine(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
            Spacer()
            Text(value)
                .font(.callout.weight(.bold))
                .foregroundStyle(AppTheme.primaryText)
                .multilineTextAlignment(.trailing)
        }
    }

    private var profilePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Select Exit Location")
                .font(.headline)
                .foregroundStyle(AppTheme.primaryText)

            ForEach(model.profiles) { profile in
                Button {
                    selectedProfileID = profile.id
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selectedProfileID == profile.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedProfileID == profile.id ? AppTheme.accent : AppTheme.secondaryText)
                        Text(flag(for: profile.regionCode))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName)
                                .font(.headline)
                                .foregroundStyle(AppTheme.primaryText)
                            Text(profile.endpointHost ?? "endpoint hidden")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.secondaryText)
                                .lineLimit(1)
                        }
                        Spacer()
                        if profile.id == model.activeProfile?.id {
                            Text("Active")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AppTheme.success)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(AppTheme.pill, in: Capsule())
                        }
                    }
                    .padding(13)
                    .background(AppTheme.row, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }
}

private struct iOSStatisticsScreen: View {
    @ObservedObject var model: iOSDashboardModel
    @State private var expandedStandbyChannelID: String?

    var body: some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    topStatus
                    liveHealthCard
                    todayReportCard
                    channelsCard
                }
                .frame(width: max(0, geometry.size.width - 32), alignment: .leading)
                .padding(.horizontal, 16)
                .safeAreaPadding(.top, 18)
                .padding(.bottom, 128)
            }
            .background(AppTheme.background.ignoresSafeArea())
        }
        .dynamicTypeSize(.medium ... .large)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var topStatus: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(model.vpnStatus.isConnectedOrConnecting ? AppTheme.success : AppTheme.secondaryText)
            Text(model.vpnStatus.rawValue.capitalized)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Image(systemName: "chevron.down")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)
            Spacer()
            Button {} label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(width: 52, height: 52)
                    .background(AppTheme.floatingButton, in: Circle())
                    .overlay(Circle().stroke(AppTheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    private var liveHealthCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                Text("Live Health")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            HStack(spacing: 12) {
                healthTile(title: "Provider", report: model.healthAssessment.directPath, seed: 0.18)
                healthTile(title: "Tunnel", report: model.healthAssessment.vpnPath, seed: 0.46)
            }

            HStack(spacing: 10) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                Text(model.probeReliabilityDetail.replacingOccurrences(of: "Best check ", with: "Best check: "))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Spacer()
                Image(systemName: "info.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
        .shadow(color: AppTheme.shadow, radius: 18, x: 0, y: 10)
    }

    private var todayReportCard: some View {
        let reports = model.channelStatistics.compactMap(\.dailyReport)
        let best = reports.max { $0.channelScore < $1.channelScore }
        let averageScore = reports.isEmpty ? 0 : reports.reduce(0) { $0 + $1.channelScore } / Double(reports.count)
        let averageRisk = reports.isEmpty ? 0 : reports.reduce(0) { $0 + $1.degradationRisk } / Double(reports.count)
        let failures = reports.reduce(0) { $0 + $1.failureCount }
        let samples = reports.reduce(0) { $0 + $1.sampleCount + $1.probeCount }

        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                Text("Today Report")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer()
                Text("\(samples)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 74), spacing: 10), count: 2), spacing: 10) {
                todayMetric("Score", "\(Int((averageScore * 100).rounded()))", color: AppTheme.accent)
                todayMetric("Risk", formatPercent(averageRisk), color: riskColor(averageRisk))
                todayMetric("Failures", "\(failures)", color: failures == 0 ? AppTheme.success : AppTheme.warning)
                todayMetric("Best", best?.region.rawValue ?? "--", color: AppTheme.primaryText)
            }

            Text(best?.summaryText ?? "No VPN channel data has been collected today.")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(3)
                .minimumScaleFactor(0.72)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
        .shadow(color: AppTheme.shadow, radius: 18, x: 0, y: 10)
    }

    private var channelsCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                Text("CoreML Channels")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer()
            }

            if model.channelStatistics.isEmpty {
                Text("No channel statistics yet.")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                if let currentChannel {
                    currentCoreMLProfileCard(currentChannel)
                } else {
                    Text("Select or connect a VPN profile to see the current CoreML channel report.")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }

                standbyRankingList
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
        .shadow(color: AppTheme.shadow, radius: 18, x: 0, y: 10)
    }

    private var currentChannel: iOSVPNChannelStatistics? {
        model.channelStatistics.first(where: \.isConnected)
            ?? model.channelStatistics.first(where: \.isActive)
    }

    private var standbyChannels: [iOSVPNChannelStatistics] {
        let currentID = currentChannel?.id
        return model.channelStatistics
            .filter { $0.id != currentID }
            .sorted { lhs, rhs in
                if lhs.coreMLScore == rhs.coreMLScore {
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
                return lhs.coreMLScore > rhs.coreMLScore
            }
    }

    private func currentCoreMLProfileCard(_ channel: iOSVPNChannelStatistics) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: channel.isConnected ? "checkmark.shield.fill" : "scope")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(channel.isConnected ? AppTheme.success : AppTheme.accent)
                    .frame(width: 48, height: 48)
                    .background(AppTheme.card.opacity(0.68), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 7) {
                    Text("CoreML Current Profile")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(AppTheme.secondaryText)
                    Text(channel.displayName)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                    Text(channel.coreMLSummary)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(3)
                        .minimumScaleFactor(0.72)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(scoreText(channel))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.accent)
                        .lineLimit(1)
                    Text("score")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .frame(width: 58, alignment: .trailing)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 72), spacing: 10), count: 3), spacing: 10) {
                channelMetric("Risk", channel.coreMLRisk.map { formatPercent($0) } ?? "--")
                channelMetric("Confidence", formatPercent(channel.coreMLConfidence))
                channelMetric("Action", channel.coreMLAction.map { actionLabel($0) } ?? "--")
                channelMetric("Success", formatPercent(channel.successRate))
                channelMetric("Latency", formatLatency(channel.averageLatencyMilliseconds))
                channelMetric("Handshake", formatLatency(channel.averageHandshakeMilliseconds))
                channelMetric("Loss", formatPercent(channel.averagePacketLoss))
                channelMetric("Failures", "\(channel.failureCount)")
                channelMetric("Checks", "\(channel.coreMLEvidenceCount)")
                channelMetric("Last", relativeTime(channel.lastSeen))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(AppTheme.row, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }

    private var standbyRankingList: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Standby Ranking")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(AppTheme.primaryText)
                Spacer()
                Text("\(standbyChannels.count)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            if standbyChannels.isEmpty {
                Text("No standby channels available.")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 12) {
                    ForEach(standbyChannels) { channel in
                        standbyRankingRow(channel)
                    }
                }
            }
        }
    }

    private func standbyRankingRow(_ channel: iOSVPNChannelStatistics) -> some View {
        let isExpanded = expandedStandbyChannelID == channel.id

        return VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    expandedStandbyChannelID = isExpanded ? nil : channel.id
                }
            } label: {
                HStack(spacing: 12) {
                    Text(channel.displayName)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                    Spacer(minLength: 8)
                    Text(scoreText(channel))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 48, alignment: .trailing)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppTheme.secondaryText)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .frame(width: 18)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 72), spacing: 10), count: 3), spacing: 10) {
                    channelMetric("Risk", channel.coreMLRisk.map { formatPercent($0) } ?? "--")
                    channelMetric("Confidence", formatPercent(channel.coreMLConfidence))
                    channelMetric("Action", channel.coreMLAction.map { actionLabel($0) } ?? "--")
                    channelMetric("Latency", formatLatency(channel.averageLatencyMilliseconds))
                    channelMetric("Success", formatPercent(channel.successRate))
                    channelMetric("Checks", "\(channel.coreMLEvidenceCount)")
                    channelMetric("Last", relativeTime(channel.lastSeen))
                }

                Text(channel.coreMLSummary)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(3)
                    .minimumScaleFactor(0.72)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(AppTheme.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }

    private func healthTile(title: String, report: PathHealthReport, seed: Double) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color(for: report.state))
                    .frame(width: 12, height: 12)
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }

            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(Int((report.successRate * 100).rounded()))%")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(color(for: report.state))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                    Text("\(formatLatency(report.averageLatencyMilliseconds)) · \(formatPercent(report.averagePacketLoss)) loss")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                Spacer(minLength: 4)
                iOSSparklineView(color: color(for: report.state), seed: seed)
                    .frame(width: 56, height: 46)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .background(AppTheme.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }

    private func channelRow(_ channel: iOSVPNChannelStatistics) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: channel.isConnected ? "checkmark.shield.fill" : "server.rack")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(channel.isConnected ? AppTheme.success : (channel.isActive ? AppTheme.accent : AppTheme.secondaryText))
                    .frame(width: 48, height: 48)
                    .background(AppTheme.card.opacity(0.68), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(regionMarker(channel.regionCode))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.primaryText)
                        Text(channel.displayName)
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(AppTheme.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                    }
                    if channel.isConnected {
                        channelBadge("Connected", color: AppTheme.success)
                    } else if channel.isActive {
                        channelBadge("Active", color: AppTheme.accent)
                    }
                    Text("\(channel.regionCode) · \(protocolLabel(channel.protocolKind)) · \(channel.sampleCount) samples")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(channel.dailyReport.map { "\(Int(($0.channelScore * 100).rounded()))" }
                        ?? channel.ranking.map { "\(Int(($0.score * 100).rounded()))" }
                        ?? "--")
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.accent)
                        .lineLimit(1)
                    Text("score")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .frame(width: 54, alignment: .trailing)

                Image(systemName: "ellipsis")
                    .font(.system(size: 19, weight: .bold))
                    .rotationEffect(.degrees(90))
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.top, 6)
                    .frame(width: 14)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 72), spacing: 10), count: 3), spacing: 10) {
                channelMetric("Latency", formatLatency(channel.averageLatencyMilliseconds))
                channelMetric("Loss", formatPercent(channel.averagePacketLoss))
                channelMetric("Success", formatPercent(channel.successRate))
                channelMetric("Handshake", formatLatency(channel.averageHandshakeMilliseconds))
                channelMetric("Failures", "\(channel.failureCount)")
                channelMetric("Last", relativeTime(channel.lastSeen))
                channelMetric("Risk", channel.dailyReport.map { formatPercent($0.degradationRisk) } ?? "--")
                channelMetric("Action", channel.dailyReport.map { actionLabel($0.recommendedActionHint) } ?? "--")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(AppTheme.row, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func scoreText(_ channel: iOSVPNChannelStatistics) -> String {
        "\(Int((channel.coreMLScore * 100).rounded()))"
    }

    private func todayMetric(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppTheme.row, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func channelBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(AppTheme.pill, in: Capsule())
    }

    private func channelMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(AppTheme.card.opacity(0.58), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    private func actionLabel(_ action: CoreMLRecommendedActionHint) -> String {
        switch action {
        case .keepCurrent:
            return "Keep"
        case .reconnect:
            return "Reconnect"
        case .switchServer:
            return "Switch"
        case .quarantine:
            return "Quarantine"
        case .askUser:
            return "Ask"
        }
    }

    private func riskColor(_ risk: Double) -> Color {
        if risk >= 0.55 {
            return .red
        }
        if risk >= 0.35 {
            return AppTheme.warning
        }
        return AppTheme.success
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

    private func color(for state: PathHealthState) -> Color {
        switch state {
        case .healthy:
            return AppTheme.success
        case .degradedSoft, .degradedHard:
            return AppTheme.warning
        case .stalled, .down, .connectedButUnusable:
            return .red
        }
    }
}

private struct iOSSparklineView: View {
    let color: Color
    let seed: Double

    var body: some View {
        GeometryReader { proxy in
            let points = sparkPoints(in: proxy.size)
            ZStack {
                sparkFill(points: points, size: proxy.size)
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.20), color.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                sparkLine(points: points)
                    .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func sparkPoints(in size: CGSize) -> [CGPoint] {
        let values = (0..<12).map { index -> Double in
            let wave = sin(Double(index) * 0.9 + seed * 8) * 0.14
            let trend = Double(index) / 18
            return min(0.9, max(0.20, 0.34 + wave + trend))
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

private struct iOSSettingsScreen: View {
    @ObservedObject var model: iOSDashboardModel
    @AppStorage("ios.showNotificationsAfterSwitch") private var showNotificationsAfterSwitch = true
    @AppStorage("ios.appearanceMode") private var appearanceMode = "System"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsSection("GENERAL") {
                    settingNavigationRow(title: "Appearance", value: appearanceMode, systemImage: "circle.lefthalf.filled")
                    settingToggleRow(title: "Connect to start", systemImage: "power", isOn: $model.connectOnStartEnabled)
                    settingToggleRow(title: "Reconnect after dropped/reset", systemImage: "arrow.clockwise", isOn: $model.reconnectAfterDropEnabled)
                    settingToggleRow(title: "Kill Switch", systemImage: "shield.fill", isOn: $model.killSwitchEnabled)
                    settingToggleRow(title: "DNS Protection", systemImage: "network", isOn: $model.dnsProtectionEnabled)
                    settingNavigationRow(title: "Language", value: "English", systemImage: "globe")
                }

                settingsSection("BEHAVIOR") {
                    settingToggleRow(title: "Auto-switch", systemImage: "arrow.triangle.2.circlepath", isOn: $model.automaticFailoverEnabled)
                    settingToggleRow(title: "Show Notification", systemImage: "bell.fill", isOn: $showNotificationsAfterSwitch)
                }

                settingsSection("ABOUT") {
                    settingNavigationRow(title: "Version", value: iOSBuildLabel, systemImage: "info.circle")
                    settingNavigationRow(title: "About Real Ai Router", value: "", systemImage: "lock.shield")
                }
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.secondaryText)
                .padding(.horizontal, 2)
            VStack(spacing: 0) {
                content()
            }
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
        }
    }

    private func settingToggleRow(title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(AppTheme.secondaryText)
                .frame(width: 22)
            Text(title)
                .font(.headline)
                .foregroundStyle(AppTheme.primaryText)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(AppTheme.accent)
        }
        .padding(14)
        .background(AppTheme.row.opacity(0.001))
    }

    private func settingNavigationRow(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(AppTheme.secondaryText)
                .frame(width: 22)
            Text(title)
                .font(.headline)
                .foregroundStyle(AppTheme.primaryText)
            Spacer()
            if !value.isEmpty {
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(14)
    }
}

private func flag(for regionCode: String?) -> String {
    guard let regionCode = regionCode?.uppercased(), regionCode.count == 2 else {
        return "🏳️"
    }
    let regionalIndicatorBase: UInt32 = 127397
    var scalars = String.UnicodeScalarView()
    for scalar in regionCode.unicodeScalars {
        guard let flagScalar = UnicodeScalar(regionalIndicatorBase + scalar.value) else {
            return "🏳️"
        }
        scalars.append(flagScalar)
    }
    return String(scalars)
}

private struct LegacyiOSDashboardView: View {
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
                    navigationCards
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
                Text("Real Ai Router")
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

            if let profile = model.displayedProfile {
                Text(routeEndpointText(for: profile))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

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

    private var navigationCards: some View {
        VStack(spacing: 12) {
            NavigationLink {
                iOSProfilesScreen(model: model)
            } label: {
                navigationCard(
                    title: "Profiles",
                    subtitle: profilesSubtitle,
                    systemImage: "server.rack",
                    detail: "\(model.profiles.count)"
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                iOSRoutingExceptionsScreen(model: model)
            } label: {
                navigationCard(
                    title: "Routing Exceptions",
                    subtitle: routingSubtitle,
                    systemImage: "arrow.triangle.branch",
                    detail: "\(model.routingExceptions.rules.count)"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var profilesSubtitle: String {
        if let profile = model.connectedProfile {
            let exit = model.observedExitIP.map { " · exit \($0)" } ?? ""
            let country = model.observedExitCountry.map { " · country \($0)" } ?? ""
            return "Connected: \(profile.displayName) · \(profile.endpointHost ?? "endpoint hidden")\(exit)\(country)"
        }

        guard let profile = model.activeProfile else {
            return "No imported profiles"
        }

        return "Active: \(profile.displayName) · \(profile.endpointHost ?? "endpoint hidden")"
    }

    private func routeEndpointText(for profile: StoredAmneziaConfigProfile) -> String {
        var parts = ["endpoint \(profile.endpointHost ?? "hidden")"]
        if let observedExitIP = model.observedExitIP {
            parts.append("exit \(observedExitIP)")
        }
        if let observedExitCountry = model.observedExitCountry {
            parts.append("country \(observedExitCountry)")
        }
        return parts.joined(separator: " · ")
    }

    private var routingSubtitle: String {
        let forceCount = model.routingExceptions.rules.filter { $0.mode == .forceVPN && $0.isEnabled }.count
        let bypassCount = model.routingExceptions.rules.filter { $0.mode == .bypassVPN && $0.isEnabled }.count
        return "\(forceCount) through VPN · \(bypassCount) without VPN"
    }

    private func navigationCard(title: String, subtitle: String, systemImage: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppTheme.primaryText)
                Text(subtitle)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 10)

            Text(detail)
                .font(.callout.monospacedDigit().weight(.bold))
                .foregroundStyle(AppTheme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppTheme.row, in: Capsule())

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(16)
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
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                NSLog("RealAiVPN iOS inline profile row double tapped id=%@ name=%@",
                                      profile.id,
                                      profile.displayName)
                                model.reconnectProfile(id: profile.id)
                            }
                        )

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

            Toggle("Kill Switch", isOn: $model.killSwitchEnabled)
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
                Text(model.dnsPolicyDiagnostic)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(2)
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
        case .degradedSoft, .degradedHard:
            return AppTheme.warning
        case .stalled, .down, .connectedButUnusable:
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

private struct iOSProfilesScreen: View {
    @ObservedObject var model: iOSDashboardModel
    @State private var showingPasteImport = false
    @State private var importingConfProfile = false
    @State private var importingJSONProfile = false
    @State private var renamingProfile: StoredAmneziaConfigProfile?
    @State private var deletingProfile: StoredAmneziaConfigProfile?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if model.profiles.isEmpty {
                    emptyState
                } else {
                    ForEach(model.profiles) { profile in
                        profileRow(profile)
                    }
                }
            }
            .padding(18)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Profiles")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingPasteImport = true
                    } label: {
                        Label("Paste key / URL", systemImage: "doc.on.clipboard")
                    }

                    Button {
                        importingConfProfile = true
                    } label: {
                        Label("Import .conf", systemImage: "doc.badge.plus")
                    }

                    Button {
                        importingJSONProfile = true
                    } label: {
                        Label("Import JSON", systemImage: "curlybraces.square")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.headline.weight(.bold))
                }
                .accessibilityLabel("Add profile")
            }
        }
        .sheet(isPresented: $showingPasteImport) {
            iOSProfilePasteImportSheet { name, rawConfig in
                model.importProfileFromPastedText(displayName: name, rawConfig: rawConfig)
            }
        }
        .sheet(item: $renamingProfile) { profile in
            iOSProfileRenameSheet(profile: profile) { newName in
                model.renameProfile(id: profile.id, displayName: newName)
            }
        }
        .confirmationDialog(
            "Delete profile?",
            isPresented: Binding(
                get: { deletingProfile != nil },
                set: { if !$0 { deletingProfile = nil } }
            ),
            presenting: deletingProfile
        ) { profile in
            Button("Delete \(profile.displayName)", role: .destructive) {
                model.deleteProfile(id: profile.id)
                deletingProfile = nil
            }
            Button("Cancel", role: .cancel) {
                deletingProfile = nil
            }
        } message: { profile in
            Text("This removes \(profile.displayName) from Real Ai Router. Other profiles and routing exceptions are kept.")
        }
        .fileImporter(
            isPresented: $importingConfProfile,
            allowedContentTypes: [UTType(filenameExtension: "conf") ?? .data],
            allowsMultipleSelection: false,
            onCompletion: importFileResult
        )
        .fileImporter(
            isPresented: $importingJSONProfile,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: importFileResult
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No imported profiles", systemImage: "server.rack")
                .font(.headline)
                .foregroundStyle(AppTheme.primaryText)
            Text("Use the import button on the main screen to add AmneziaWG .conf or Shadowrocket VLESS profiles.")
                .font(.callout)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func profileRow(_ profile: StoredAmneziaConfigProfile) -> some View {
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

                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.displayName)
                            .font(.headline)
                            .foregroundStyle(AppTheme.primaryText)
                            .lineLimit(2)
                        Text("\(profile.regionCode ?? "Unknown") · \(profile.endpointHost ?? "endpoint hidden")")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 10)

                    Text(profile.kind.rawValue)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.accent)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    NSLog("RealAiVPN iOS profile row double tapped id=%@ name=%@",
                          profile.id,
                          profile.displayName)
                    model.reconnectProfile(id: profile.id)
                }
            )

            Button {
                renamingProfile = profile
            } label: {
                Image(systemName: "pencil")
                    .font(.callout.weight(.bold))
                    .frame(width: 42, height: 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.secondaryText)
            .accessibilityLabel("Rename \(profile.displayName)")

            Button(role: .destructive) {
                deletingProfile = profile
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
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                model.importProfileFromPastedText(displayName: url.deletingPathExtension().lastPathComponent, rawConfig: imported)
            } catch {
                model.reportStatus("Could not import \(url.lastPathComponent): \(error.localizedDescription)")
            }
        case .failure(let error):
            model.reportStatus("Could not import config: \(error.localizedDescription)")
        }
    }
}

private struct iOSProfilePasteImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var rawConfig = ""
    let onImport: (String, String) -> Void

    private var trimmedConfig: String {
        rawConfig.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Display name") {
                    TextField("Optional name", text: $displayName)
                }

                Section("Key / URL / Config") {
                    TextEditor(text: $rawConfig)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 220)
                }

                Section {
                    Text("Paste a vpn:// key, VLESS URL, subscription URL, or raw config. Secrets stay local.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("Add Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        onImport(displayName, rawConfig)
                        dismiss()
                    }
                    .disabled(trimmedConfig.isEmpty)
                }
            }
        }
    }
}

private struct iOSProfileRenameSheet: View {
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
        NavigationStack {
            Form {
                Section("Profile name") {
                    TextField("Name", text: $displayName)
                }

                Section {
                    Text(profile.endpointHost ?? profile.kind.rawValue)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("Rename Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(displayName)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
    }
}

private struct iOSRoutingExceptionsScreen: View {
    @ObservedObject var model: iOSDashboardModel
    @State private var forceVPNException = ""
    @State private var bypassVPNException = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                routingForm
                rulesList
            }
            .padding(18)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Routing")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.reconnectVPNWithKillSwitch()
                } label: {
                    Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(reconnectDisabled)
                .accessibilityLabel("Reconnect VPN with Kill Switch")
            }
        }
    }

    private var reconnectDisabled: Bool {
        model.vpnStatus == .connecting || model.vpnStatus == .disconnecting || model.activeProfile == nil
    }

    private var routingForm: some View {
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
        }
        .padding(18)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var rulesList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Rules", systemImage: "list.bullet")
                .font(.headline)
                .foregroundStyle(AppTheme.secondaryText)

            if model.routingExceptions.rules.isEmpty {
                Text("No routing exceptions yet.")
                    .font(.callout)
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                ForEach(model.routingExceptions.rules) { rule in
                    routingExceptionRow(rule)
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
            Color(red: 0.97, green: 0.99, blue: 1.00),
            Color(red: 0.92, green: 0.97, blue: 0.99)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let card = Color.white.opacity(0.82)
    static let row = Color(red: 0.96, green: 0.985, blue: 1.0).opacity(0.78)
    static let pill = Color(red: 0.89, green: 0.97, blue: 0.96)
    static let floatingButton = Color.white.opacity(0.72)
    static let border = Color.black.opacity(0.08)
    static let shadow = Color(red: 0.10, green: 0.22, blue: 0.28).opacity(0.10)
    static let primaryText = Color(red: 0.06, green: 0.08, blue: 0.11)
    static let secondaryText = Color(red: 0.38, green: 0.43, blue: 0.50)
    static let accent = Color(red: 0.00, green: 0.64, blue: 0.58)
    static let success = Color(red: 0.14, green: 0.70, blue: 0.52)
    static let warning = Color(red: 0.95, green: 0.50, blue: 0.16)
}
