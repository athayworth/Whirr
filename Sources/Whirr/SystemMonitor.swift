import Foundation
import Observation
import WhirrCore

@MainActor
@Observable
final class SystemMonitor {
    var diagnoses: [Diagnosis] = []
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
    /// Resets to empty on app restart — in-memory only, like
    /// `inMemoryHistory` for the system view.
    var dockerHistory = DockerHistoryTracker()

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
        self.pipeline = SamplingPipeline(rulesConfig: config)
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

    var worstSeverity: Severity {
        diagnoses.map(\.severity).max() ?? .ok
    }

    /// False until the first sample has produced data. Lets the UI
    /// distinguish "no problems detected" (worstSeverity == .ok with data)
    /// from "we don't know yet" (no data) — the latter shouldn't render as
    /// a confident green check on launch.
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

            // Wall-clock-anchored fire schedule. We aim to fire each tick at
            // `nextFire`, an instant on `ContinuousClock` (monotonic, advances
            // through sleep/wake). If the work itself or a system stall makes
            // us late, we *skip ahead* to the next clean interval slot rather
            // than fire back-to-back catching up — that would compound CPU
            // pressure exactly when the system is already struggling. A long
            // laptop sleep therefore produces one tick on wake, not 600.
            var nextFire = ContinuousClock.now
            while !Task.isCancelled {
                // Read the sampling interval *each* iteration so changes from
                // the Settings panel apply on the next slot without restart.
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

                // Poll Docker every other tick (~2× interval) — the API is
                // slow per request and per-container stats don't change
                // minute to minute. Reuse the last-known list on intermediate
                // ticks so the rules engine still sees container data.
                if tickCount % 2 == 0 {
                    lastKnownContainers = await dockerClient.listContainers()
                }
                let result = await pipeline.tick(containers: lastKnownContainers)
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
        self.diagnoses = result.diagnoses
        // `uniquingKeysWith` over `uniqueKeysWithValues` — duplicate pids
        // shouldn't happen but a trap on the sampling path would take down
        // the whole monitor. Defensive, not corrective.
        self.processesByPid = Dictionary(
            result.processes.map { ($0.pid, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Always append the current tick to in-memory history. This works
        // regardless of daemon state and gives the history strip something
        // to show on a fresh install before the daemon's file gets used.
        let worst = result.diagnoses.map(\.severity).max() ?? .ok
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

        // Prefer the daemon's history when it has more points than our
        // in-memory buffer — daemon persists across app restarts, in-memory
        // doesn't, so the daemon's version reaches further back.
        self.trendHistory = result.history.count > inMemoryHistory.count
            ? result.history
            : inMemoryHistory

        self.lastUpdated = Date()
        notifications.process(result.diagnoses)
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
