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

    private let pipeline = SamplingPipeline()
    private let taskBox = TaskBox()
    private let notifications = NotificationService()
    /// Exposed (non-private) so the menu bar's container drill-in can issue
    /// Stop / Restart actions through the same actor that does the polling.
    let dockerClient = DockerClient()
    /// In-memory rolling history maintained by the menu bar app itself.
    /// When the daemon writes history.json that's preferred (it persists
    /// across app restarts and reaches back further); otherwise we fall
    /// back to this buffer so the history view works without the daemon.
    private var inMemoryHistory: [TrendPoint] = []
    private static let inMemoryHistoryCapacity = 600  // ~30 min at 3 s

    init() {
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
            // Prime the per-process CPU sampler so the next sample produces real deltas.
            _ = await pipeline.tick(containers: [])
            try? await Task.sleep(for: .seconds(2))

            var tickCount = 0
            var lastKnownContainers: [DockerContainer] = []
            while !Task.isCancelled {
                // Poll Docker every other tick (~6 s) — the API is slow per
                // request and per-container stats don't change minute to
                // minute. Reuse the last-known list on intermediate ticks so
                // the rules engine still sees container data.
                if tickCount % 2 == 0 {
                    lastKnownContainers = await dockerClient.listContainers()
                }
                let result = await pipeline.tick(containers: lastKnownContainers)
                await MainActor.run {
                    self?.apply(result)
                    self?.dockerContainers = lastKnownContainers
                }
                tickCount += 1
                try? await Task.sleep(for: .seconds(3))
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
