import AppKit
import Foundation
import Observation
import WhirrCore

/// Main-window sidebar destinations.
enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case overview, mac, connection, history, developer, learn
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .mac: return "Mac"
        case .connection: return "Connection"
        case .history: return "History"
        case .developer: return "Developer"
        case .learn: return "Learn"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .mac: return "desktopcomputer"
        case .connection: return "wifi"
        case .history: return "clock.arrow.circlepath"
        case .developer: return "hammer"
        case .learn: return "book"
        }
    }

    /// The findings area this section shows, if any.
    var area: Diagnosis.Area? {
        switch self {
        case .mac: return .mac
        case .connection: return .connection
        case .developer: return .developer
        case .overview, .history, .learn: return nil
        }
    }
}

@MainActor
@Observable
final class SystemMonitor {
    /// Per-diagnosis contexts (duration + trend). The menu bar filters
    /// snoozed items out for display; header severity + notifications
    /// also skip them.
    var diagnosisContexts: [DiagnosisContext] = []
    /// Overview headline + per-area status, recomputed each tick from
    /// `diagnosisContexts` minus snoozed/muted findings.
    var verdict: Verdict = .allClear
    /// "Can I keep going?" summary shown at the top of the menu.
    var headroom: HeadroomAssessment = .empty
    var secondsPerSample: Double = 3
    var topProcesses: [ProcessSample] = []
    var topMemoryProcesses: [ProcessSample] = []
    /// Indexed by pid for fast parent-process lookup from the drill-in
    /// view. Rebuilt each tick from the full sample set.
    var processesByPid: [Int32: ProcessSample] = [:]
    var systemSnapshot: SystemSnapshot = .empty
    var lastUpdated: Date = .distantPast
    /// Recent history written by the daemon (empty when daemon isn't installed).
    /// Newest points last.
    var trendHistory: [TrendPoint] = []
    /// Per-container stats from Docker's Unix socket. Empty when Docker isn't
    /// running or the socket isn't reachable.
    var dockerContainers: [DockerContainer] = []
    /// Ring buffer of per-container CPU+memory samples, indexed by short
    /// container ID. Drives the sparkline in the expanded detail panel.
    /// Resets to empty on app restart — in-memory only.
    var dockerHistory = DockerHistoryTracker()
    /// Per-project runtime state derived from `~/.harbr/config.json` +
    /// the current process table. Empty when Harbr isn't configured.
    var harbrStatuses: [HarbrProjectStatus] = []
    /// Health of the root sampler's snapshot file this tick.
    var daemonStatus: DaemonStatus = .absent

    // MARK: Connection

    /// Latest passive connection state (pings + Wi-Fi link).
    var connection: ConnectionSnapshot = .empty
    /// Non-nil while a "Check my connection" test is running.
    var connectionTestPhase: ConnectionTestRunner.Phase?
    /// Most recent completed full test (this session or loaded from disk).
    var latestConnectionTest: ConnectionTestResult?
    /// Router IP, for the channel-change how-to ("open http://…").
    var gatewayIP: String?
    let connectionStore = ConnectionHistoryStore()
    private let connectionMonitor: ConnectionMonitor
    private let connectionTestRunner = ConnectionTestRunner()

    // MARK: Navigation

    /// Current main-window section. Lives here so the menu popover and
    /// action buttons can jump the window to a section.
    var selectedSection: SidebarItem? = .overview
    /// Set by actions that want the Connection section to start a test
    /// as soon as it appears.
    var pendingConnectionTest = false
    /// How-to sheet currently shown over the main window.
    var presentedHowTo: SuggestedAction.HowTo?

    /// Currently-expanded process row (nil = nothing expanded). Lives on
    /// the monitor rather than as `@State` in MenuBarView so the
    /// expanded row survives closing and reopening the menu bar panel —
    /// MenuBarExtra rebuilds the SwiftUI view on each open, which would
    /// otherwise reset local `@State`.
    var expandedPid: Int32? = nil
    /// Same idea for Docker containers. Independent from `expandedPid`
    /// so a process and a container can be expanded simultaneously.
    var expandedContainerId: String? = nil

    let snoozeStore = SnoozeStore()
    /// Persistent log of closed diagnosis incidents. Written by the
    /// pipeline; read by the Insights tab in Settings.
    let incidentLog = IncidentLog()
    /// Tracks which apps the user has focused recently — feeds the
    /// idle-hogs narrative's "don't flag Arc while I'm reading in it"
    /// exemption. Sampled once per tick on the main actor before
    /// handing the snapshot to the pipeline.
    private let frontmostAppTracker = FrontmostAppTracker()

    private let pipeline: SamplingPipeline
    private let taskBox = TaskBox()
    private let notifications = NotificationService()
    /// Outcome of loading rules.json at launch — surfaced in the Settings
    /// → Rules tab so the user knows whether their file took effect or
    /// fell back to defaults.
    let rulesConfigLoadResult: RulesConfigStore.LoadResult
    /// Exposed (non-private) so the menu bar's container drill-in can issue
    /// Stop / Restart actions through the same actor that does the polling.
    let dockerClient = DockerClient()
    /// SMAppService wrapper that surfaces "advanced sampling daemon" state
    /// to the UI. The menu bar shows an enable / approve row when its
    /// state requires the user to do something.
    let daemonManager = DaemonManager()
    /// In-memory rolling history maintained by the menu bar app itself.
    /// When the daemon writes history.json that's preferred (it persists
    /// across app restarts and reaches back further); otherwise we fall
    /// back to this buffer so the history view works without the daemon.
    private var inMemoryHistory: [TrendPoint] = []
    private static let inMemoryHistoryCapacity = 600  // ~30 min at 3 s

    init() {
        // Load rules.json once at startup. Changes to the file require an
        // app restart to take effect — documented in Settings → Rules.
        let store = RulesConfigStore()
        let (config, result) = store.load()
        self.rulesConfigLoadResult = result
        // The monitor owns the incident log so both the pipeline
        // (writer) and the Insights view (reader) share one instance
        // and see the same in-memory cache.
        self.pipeline = SamplingPipeline(rulesConfig: config, incidentLog: incidentLog)
        self.connectionMonitor = ConnectionMonitor(store: connectionStore)
        self.latestConnectionTest = connectionStore.tests().last
        start()
        startConnectionMonitoring()
    }

    deinit {
        taskBox.cancel()
    }

    var statusIcon: String {
        switch worstSeverity {
        case .critical: return "fanblades.fill"
        case .warning:  return "fanblades"
        case .ok:       return "fanblades"
        }
    }

    /// Worst severity across gated, visible *problems* (see
    /// `VerdictSelector`). Notes and young problems don't color the
    /// icon — that's what keeps it from crying wolf.
    var worstSeverity: Severity { verdict.worst }

    /// Snoozed or muted — hidden from the primary UI, the icon and
    /// notifications.
    func isHidden(_ title: String) -> Bool {
        snoozeStore.isSnoozed(title) || snoozeStore.isMuted(title)
    }

    /// The diagnosis list rendered in sections — minus anything hidden.
    var visibleDiagnoses: [Diagnosis] {
        diagnosisContexts
            .filter { !isHidden($0.diagnosis.title) }
            .map(\.diagnosis)
    }

    /// False until the first sample has produced data. Lets the UI
    /// distinguish "no problems detected" (worstSeverity == .ok with data)
    /// from "we don't know yet" (no data).
    var hasSampledYet: Bool { lastUpdated != .distantPast }

    private func start() {
        let pipeline = self.pipeline
        let dockerClient = self.dockerClient
        taskBox.task = Task { [weak self] in
            // Prime the per-process CPU sampler so the next sample produces
            // real deltas. The 2 s settle gives the kernel a window to
            // populate per-process counters before our first published tick.
            _ = await pipeline.tick(containers: [])
            try? await Task.sleep(for: .seconds(2))

            var tickCount = 0
            var lastKnownContainers: [DockerContainer] = []

            // Wall-clock-anchored fire schedule. See the note in the prior
            // implementation — we skip missed slots rather than fire
            // back-to-back after a stall.
            var nextFire = ContinuousClock.now
            while !Task.isCancelled {
                let intervalSeconds = Preferences.samplingIntervalSeconds
                let interval: Duration = .seconds(intervalSeconds)

                nextFire += interval
                let now = ContinuousClock.now
                if nextFire < now {
                    nextFire = now + interval
                }

                do {
                    try await Task.sleep(until: nextFire, clock: .continuous)
                } catch {
                    return  // task cancelled
                }

                if tickCount % 2 == 0 {
                    lastKnownContainers = await dockerClient.listContainers()
                }
                // Sample the frontmost app on the main actor before
                // the pipeline runs — NSWorkspace can't be called off
                // the main actor. Snapshot returns the set of bundle
                // IDs the user has focused within the tracker's window.
                let recentBundleIds = await MainActor.run {
                    self?.frontmostAppTracker.recordAndSnapshot() ?? []
                }
                let connection = await self?.connectionMonitor.snapshot() ?? .empty
                let result = await pipeline.tick(
                    containers: lastKnownContainers,
                    recentlyActiveBundleIds: recentBundleIds,
                    connection: connection
                )
                await MainActor.run { self?.connection = connection }
                await MainActor.run {
                    self?.apply(result)
                    self?.dockerContainers = lastKnownContainers
                    self?.dockerHistory.record(lastKnownContainers, at: Date())
                }
                tickCount += 1
            }
        }
    }

    private func apply(_ result: SamplingPipeline.Result) {
        self.systemSnapshot = result.snapshot
        self.topProcesses = Array(result.processes.prefix(8))
        // Sort by memory and take the top 5 with >= 500 MB so we don't fill
        // the menu with idle background processes that happen to hold 100 MB.
        self.topMemoryProcesses = result.processes
            .sorted { $0.memoryBytes > $1.memoryBytes }
            .prefix(5)
            .filter { $0.memoryBytes >= 500 * 1_048_576 }
        self.diagnosisContexts = result.diagnosisContexts
        self.verdict = VerdictSelector.select(result.diagnosisContexts, isHidden: { [snoozeStore] title in
            snoozeStore.isSnoozed(title) || snoozeStore.isMuted(title)
        }, load: result.ownerLoad)
        self.headroom = result.headroom
        self.secondsPerSample = result.secondsPerSample
        self.harbrStatuses = result.harbrStatuses
        self.daemonStatus = result.daemonStatus
        // `uniquingKeysWith` over `uniqueKeysWithValues` — duplicate pids
        // shouldn't happen but a trap on the sampling path would take down
        // the whole monitor.
        self.processesByPid = Dictionary(
            result.processes.map { ($0.pid, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Always append the current tick to in-memory history. This works
        // regardless of daemon state and gives the history strip something
        // to show on a fresh install before the daemon's file gets used.
        // Snoozed diagnoses don't drive worstSeverity for the header — the
        // history strip uses the *visible* worst severity for the same
        // reason (a snoozed critical shouldn't paint the strip red).
        let worst = verdict.worst
        inMemoryHistory.append(TrendPoint(
            capturedAt: Date(),
            memoryPressure: result.snapshot.memoryPressure,
            memoryUsedBytes: result.snapshot.memoryUsedBytes,
            swapUsedBytes: result.snapshot.swapUsedBytes,
            loadOneMinute: result.snapshot.loadAverage.oneMinute,
            worstSeverity: worst
        ))
        if inMemoryHistory.count > Self.inMemoryHistoryCapacity {
            inMemoryHistory.removeFirst(inMemoryHistory.count - Self.inMemoryHistoryCapacity)
        }

        self.trendHistory = result.history.count > inMemoryHistory.count
            ? result.history
            : inMemoryHistory

        self.lastUpdated = Date()
        // Notifications only for problems that pass the notify gate
        // (critical, ≥ 5 min, actionable) and aren't snoozed or muted.
        // One notification per story, so one cause can't raise several.
        let notifiable = verdict.stories
            .filter(VerdictSelector.shouldNotify)
            .map(\.headline.diagnosis)
        notifications.process(notifiable, presentTitles: Set(result.diagnoses.map(\.title)))
    }
}

// MARK: - Connection

extension SystemMonitor {
    /// Starts the passive watcher and pauses it across sleep, so a closed
    /// lid never reads as an outage.
    fileprivate func startConnectionMonitoring() {
        let monitor = connectionMonitor
        Task { await monitor.start() }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { await monitor.setPaused(true) }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task {
                // Let Wi-Fi re-associate before judging the connection.
                try? await Task.sleep(for: .seconds(10))
                await monitor.setPaused(false)
            }
        }
        Task { [weak self] in
            let ip = await Task.detached { GatewayResolver.current()?.ip }.value
            self?.gatewayIP = ip
        }
    }

    var isDeveloperRelevant: Bool {
        !dockerContainers.isEmpty || !harbrStatuses.isEmpty || Preferences.alwaysShowDeveloper
    }

    /// Visible (not snoozed/muted) contexts for one area, problems first.
    func contexts(in area: Diagnosis.Area) -> [DiagnosisContext] {
        diagnosisContexts
            .filter { $0.diagnosis.area == area && !isHidden($0.diagnosis.title) }
            .sorted { ($0.diagnosis.tier == .problem ? 0 : 1, -$0.diagnosis.severity.rawValue)
                    < ($1.diagnosis.tier == .problem ? 0 : 1, -$1.diagnosis.severity.rawValue) }
    }

    /// Snoozed or muted contexts for one area.
    func hiddenContexts(in area: Diagnosis.Area) -> [DiagnosisContext] {
        diagnosisContexts.filter { $0.diagnosis.area == area && isHidden($0.diagnosis.title) }
    }

    func runConnectionTest() {
        guard connectionTestPhase == nil else { return }
        connectionTestPhase = .measuringIdle
        let runner = connectionTestRunner
        let store = connectionStore
        let passive = connectionMonitor
        // Frozen now, so the saved result is always graded against the
        // 10 minutes before it — not whatever is happening when viewed.
        let before = PassiveBefore(gateway: connection.gateway10m, internet: connection.internet10m,
                                   gatewayPingable: connection.gatewayPingable, isWired: connection.isWired)
        Task { [weak self] in
            // The test saturates the line on purpose. Passive pings taken
            // meanwhile would record self-inflicted stalls into history
            // and skew the per-channel comparison, so pause them.
            await passive.setPaused(true)
            defer { Task { await passive.setPaused(false) } }
            let result = await runner.run(before: before) { phase in
                Task { @MainActor in self?.connectionTestPhase = phase == .done ? nil : phase }
            }
            store.saveTest(result)
            await MainActor.run {
                self?.latestConnectionTest = result
                self?.connectionTestPhase = nil
            }
        }
    }

    func stopAllDockerContainers() async {
        for container in dockerContainers {
            try? await dockerClient.stop(containerId: container.id)
        }
    }
}

/// Holds the sampling task in a nonisolated box so it can be cancelled from deinit
/// without crossing actor boundaries.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _task: Task<Void, Never>?

    var task: Task<Void, Never>? {
        get { lock.withLock { _task } }
        set { lock.withLock { _task = newValue } }
    }

    func cancel() {
        lock.withLock { _task?.cancel() }
    }
}

// MARK: - HeadroomAssessment placeholder for empty state

extension HeadroomAssessment {
    /// Placeholder for the pre-first-sample state so the UI can render
    /// something (dimmed via `hasSampledYet`) instead of nothing.
    static let empty = HeadroomAssessment(
        availableMemoryBytes: 0,
        totalMemoryBytes: 0,
        verdict: .comfortable,
        headline: "Sampling…",
        context: "Reading system state.",
        topHogName: nil,
        topHogBytes: nil
    )
}
