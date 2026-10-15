import Foundation
import Observation
import StillHereCore

/// The menu's state: the latest scan, probe results, refresh status and the stop flow.
/// All detection work is awaited on the detector (off the main actor); only results are
/// assigned here.
@Observable
final class ServerListModel {
    enum RefreshReason: Hashable {
        case timer, menuOpened, manual, settingsChanged, serverStopped
    }

    private(set) var servers: [ServerEntry] = []
    /// Running agent sessions and the checkouts they share.
    private(set) var sessionOverview = SessionOverview.empty
    private(set) var probeRecords: [ServerEntry.ID: ProbeRecord] = [:]
    private(set) var lastError: String?
    private(set) var isRefreshing = false
    private(set) var lastRefreshed: Date?
    /// Set by the panel; probes only run while someone can see them.
    var isPanelOpen = false

    let settings: SettingsStore
    let stopFlow: StopFlow

    @ObservationIgnored private let detector: any ServerDetector
    @ObservationIgnored private let sessionSource: any SessionSource
    @ObservationIgnored private let clock: any NowProvider
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var probes = ProbeScheduler()
    @ObservationIgnored private var observedSettings: ObservedSettings?

    init(
        detector: any ServerDetector,
        sessionSource: any SessionSource = FakeSessionSource([]),
        settings: SettingsStore,
        signaller: ProcessSignaller,
        clock: any NowProvider = SystemNow(),
        stopTimeout: Duration = .seconds(3),
        stopPollInterval: Duration = .milliseconds(250)
    ) {
        self.detector = detector
        self.sessionSource = sessionSource
        self.settings = settings
        self.clock = clock
        stopFlow = StopFlow(
            signaller: signaller,
            exitTimeout: stopTimeout,
            pollInterval: stopPollInterval
        )
        stopFlow.onStopped = { [weak self] in await self?.refresh(.serverStopped) }
    }

    // MARK: Derived state

    var visibleServers: [ServerEntry] { servers.filter { !$0.isHidden } }
    var hiddenServers: [ServerEntry] { servers.filter(\.isHidden) }
    /// The menu bar count: visible servers, whether or not hidden ones are shown.
    var visibleCount: Int { servers.count { !$0.isHidden } }
    /// Independent agent sessions sharing a checkout.
    var collisionCount: Int { sessionOverview.collisions.count }
    /// Visible servers whose launching agent session has ended.
    var orphanCount: Int { servers.count { !$0.isHidden && $0.agent?.isOrphaned == true } }

    /// The probe for this exact process, if one has been taken.
    func probe(for entry: ServerEntry) -> ProbeResult? {
        guard let record = probeRecords[entry.id], record.key == entry.probeKey else { return nil }
        return record.result
    }

    /// The scan's guess, refined by response headers when it was only a runtime guess.
    func framework(for entry: ServerEntry) -> FrameworkGuess {
        probe(for: entry).map { FrameworkDetector.refine(entry.framework, with: $0) } ?? entry.framework
    }

    /// The URL to show, copy and open: HTTPS once a probe found a TLS-only server.
    func url(for entry: ServerEntry) -> URL { entry.url(for: probe(for: entry)) }

    func now() -> Date { clock.now }

    // MARK: Polling

    /// Starts the refresh loop once, and restarts it whenever a setting that affects
    /// scanning changes.
    func start() {
        guard pollingTask == nil else { return }
        observeSettings()
        restartPolling()
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func restartPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = await self?.pollOnce() else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func pollOnce() async -> Double {
        await refresh(.timer)
        return settings.refreshInterval
    }

    private struct ObservedSettings: Equatable {
        var interval: Double
        var config: IgnoreConfiguration
        var probeHTTP: Bool
    }

    private func currentObservedSettings() -> ObservedSettings {
        ObservedSettings(
            interval: settings.refreshInterval,
            config: settings.ignoreConfiguration,
            probeHTTP: settings.probeHTTP
        )
    }

    private func observeSettings() {
        observedSettings = withObservationTracking {
            currentObservedSettings()
        } onChange: { [weak self] in
            Task { @MainActor in self?.settingsDidChange() }
        }
    }

    private func settingsDidChange() {
        let previous = observedSettings
        observeSettings()
        guard observedSettings != previous, pollingTask != nil else { return }
        restartPolling() // refreshes immediately with the new rules, then sleeps the new interval
    }

    // MARK: Refresh

    /// Scans (coalesced: at most one scan in flight) and then probes stale visible rows
    /// while the panel is open.
    func refresh(_ reason: RefreshReason) async {
        await scan()
        if isPanelOpen, settings.probeHTTP {
            await probeStaleEntries(force: reason == .manual)
        }
    }

    private func scan() async {
        if let scanTask {
            await scanTask.value
            return
        }
        let task = Task { await performScan() }
        scanTask = task
        await task.value
        if scanTask == task { scanTask = nil }
    }

    private func performScan() async {
        isRefreshing = true
        defer { isRefreshing = false }
        // Sessions only seconds old (one-shot `claude -p` helpers) would flicker in and out.
        let now = clock.now
        let settled = await sessionSource.sessions().filter {
            now.timeIntervalSince($0.startTime) >= SessionScanner.minimumCollisionAge
        }
        let overview = SessionOverview(sessions: settled, now: now)
        if overview != sessionOverview { sessionOverview = overview }
        do {
            let entries = try await detector.scan(config: settings.ignoreConfiguration)
            if entries != servers { servers = entries }
            stopFlow.prune(keeping: servers)
            lastError = nil
            lastRefreshed = clock.now
            dropStaleProbes()
        } catch {
            lastError = Self.describe(error) // keep the previous list
        }
    }

    private func dropStaleProbes() {
        let current = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0.probeKey) })
        let kept = probeRecords.filter { current[$0.key] == $0.value.key }
        if kept.count != probeRecords.count { probeRecords = kept }
    }

    private func probeStaleEntries(force: Bool) async {
        let batch = probes.entriesNeedingProbe(
            visibleServers,
            records: force ? [:] : probeRecords,
            now: clock.now,
            maxAge: settings.refreshInterval
        )
        guard !batch.isEmpty else { return }
        probes.begin(batch)
        defer { batch.forEach { probes.end($0.probeKey) } }
        await ProbeScheduler.probe(batch, using: detector) { key, result in
            apply(result, for: key)
        }
    }

    /// Stores a probe only if the port still belongs to the process that was probed.
    func apply(_ result: ProbeResult, for key: ServerEntry.ProbeKey) {
        guard servers.contains(where: { $0.probeKey == key }) else { return }
        probeRecords[key.entryID] = ProbeRecord(key: key, result: result, probedAt: clock.now)
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case DetectionError.commandFailed(let executable, let status):
            "\((executable as NSString).lastPathComponent) failed (exit \(status))."
        case SubprocessError.timedOut(let executable):
            "\((executable as NSString).lastPathComponent) timed out."
        case SubprocessError.launchFailed(let executable, _):
            "Couldn't run \((executable as NSString).lastPathComponent)."
        case SubprocessError.cancelled:
            "Refresh cancelled."
        default:
            error.localizedDescription
        }
    }
}
