import Foundation
import Observation
import WhirrCore

@MainActor
@Observable
final class SystemMonitor {
    /// Per-diagnosis contexts (duration + trend). The menu bar filters
    /// snoozed items out for display; header severity + notifications
    /// also skip them.
    var diagnosisContexts: [DiagnosisContext] = []
    /// "Can I keep going?" summary shown at the top of the menu.
    var headroom: HeadroomAssessment = .empty
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
        start()
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

    /// Worst severity across *unsnoozed* contexts. Snoozed diagnoses
    /// don't drive the header color — that's the whole point of snooze:
    /// the user has said "I know, I don't want to be reminded."
    var worstSeverity: Severity {
        visibleDiagnoses.map(\.severity).max() ?? .ok
    }

    /// The diagnosis list rendered in the menu — minus anything snoozed.
    var visibleDiagnoses: [Diagnosis] {
        diagnosisContexts
            .filter { !snoozeStore.isSnoozed($0.diagnosis.title) }
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
                let result = await pipeline.tick(
                    containers: lastKnownContainers,
                    recentlyActiveBundleIds: recentBundleIds
                )
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
        self.headroom = result.headroom
        self.harbrStatuses = result.harbrStatuses
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
        let worst = visibleDiagnoses.map(\.severity).max() ?? .ok
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
        // Notifications also skip snoozed diagnoses — the user has said
        // "don't alert me on this" and a critical-firing snoozed rule
        // shouldn't ping them.
        let unsnoozed = result.diagnosisContexts
            .filter { !snoozeStore.isSnoozed($0.diagnosis.title) }
            .map(\.diagnosis)
        notifications.process(unsnoozed)
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
