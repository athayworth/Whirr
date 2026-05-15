import Foundation
import Observation
import WhirrCore

@MainActor
@Observable
final class SystemMonitor {
    var diagnoses: [Diagnosis] = []
    var topProcesses: [ProcessSample] = []
    var topMemoryProcesses: [ProcessSample] = []
    var systemSnapshot: SystemSnapshot = .empty
    var lastUpdated: Date = .distantPast
    /// Recent history written by the daemon (empty when daemon isn't installed).
    /// Newest points last.
    var trendHistory: [TrendPoint] = []

    private let pipeline = SamplingPipeline()
    private let taskBox = TaskBox()
    private let notifications = NotificationService()
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

    private func start() {
        let pipeline = self.pipeline
        taskBox.task = Task { [weak self] in
            // Prime the per-process CPU sampler so the next sample produces real deltas.
            _ = await pipeline.tick()
            try? await Task.sleep(for: .seconds(2))

            while !Task.isCancelled {
                let result = await pipeline.tick()
                await MainActor.run { self?.apply(result) }
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

actor SamplingPipeline {
    struct Result: Sendable {
        let snapshot: SystemSnapshot
        let processes: [ProcessSample]
        let diagnoses: [Diagnosis]
        let history: [TrendPoint]
        let source: Source

        enum Source: Sendable { case daemon, inProcess }
    }

    /// File written by `whirr-sampler` when the launchd daemon is installed.
    /// If this file exists and is fresh, we use it (covers root processes);
    /// otherwise we fall back to in-process sampling (works without the daemon).
    private static let daemonSnapshotPath = "/Library/Application Support/Whirr/snapshot.json"
    private static let daemonHistoryPath = "/Library/Application Support/Whirr/history.json"

    /// How stale the daemon's file can be before we treat it as gone.
    /// Tied to the daemon's 3-second interval with comfortable slack.
    private static let daemonFreshnessWindow: TimeInterval = 10

    private let processSampler = ProcessSampler()
    private let rules = RulesEngine()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func tick() -> Result {
        if let fromDaemon = readDaemonSnapshot() {
            return fromDaemon
        }
        let snapshot = SystemSampler.sample()
        let processes = processSampler.sample()
        let diagnoses = rules.evaluate(snapshot: snapshot, processes: processes)
        // No daemon means no shared history file — return what we have
        // (just the current point isn't useful, so an empty array signals
        // "history not available" to the UI).
        return Result(
            snapshot: snapshot,
            processes: processes,
            diagnoses: diagnoses,
            history: [],
            source: .inProcess
        )
    }

    private func readDaemonSnapshot() -> Result? {
        let url = URL(fileURLWithPath: Self.daemonSnapshotPath)
        guard let data = try? Data(contentsOf: url, options: .uncached) else { return nil }
        guard let payload = try? decoder.decode(SnapshotPayload.self, from: data) else { return nil }
        guard payload.formatVersion == SnapshotPayload.currentFormatVersion else { return nil }
        guard Date().timeIntervalSince(payload.capturedAt) < Self.daemonFreshnessWindow else { return nil }
        // Re-run the rules engine on the daemon's snapshot + processes rather
        // than trusting payload.diagnoses. The daemon's rule set is whatever
        // shipped with the installed binary, which may be stale relative to
        // the app's; this way rule changes ship with the next app build.
        let diagnoses = rules.evaluate(snapshot: payload.snapshot, processes: payload.processes)
        return Result(
            snapshot: payload.snapshot,
            processes: payload.processes,
            diagnoses: diagnoses,
            history: readDaemonHistory(),
            source: .daemon
        )
    }

    private func readDaemonHistory() -> [TrendPoint] {
        let url = URL(fileURLWithPath: Self.daemonHistoryPath)
        guard let data = try? Data(contentsOf: url, options: .uncached) else { return [] }
        guard let history = try? decoder.decode(TrendHistory.self, from: data),
              history.formatVersion == TrendHistory.currentFormatVersion else {
            return []
        }
        return history.points
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
