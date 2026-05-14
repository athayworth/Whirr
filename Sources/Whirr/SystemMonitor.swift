import Foundation
import Observation
import WhirrCore

@MainActor
@Observable
final class SystemMonitor {
    var diagnoses: [Diagnosis] = []
    var topProcesses: [ProcessSample] = []
    var systemSnapshot: SystemSnapshot = .empty
    var lastUpdated: Date = .distantPast

    private let pipeline = SamplingPipeline()
    private let taskBox = TaskBox()

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
        self.diagnoses = result.diagnoses
        self.lastUpdated = Date()
    }
}

actor SamplingPipeline {
    struct Result: Sendable {
        let snapshot: SystemSnapshot
        let processes: [ProcessSample]
        let diagnoses: [Diagnosis]
        let source: Source

        enum Source: Sendable { case daemon, inProcess }
    }

    /// File written by `whirr-sampler` when the launchd daemon is installed.
    /// If this file exists and is fresh, we use it (covers root processes);
    /// otherwise we fall back to in-process sampling (works without the daemon).
    private static let daemonSnapshotPath = "/Library/Application Support/Whirr/snapshot.json"

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
        return Result(snapshot: snapshot, processes: processes, diagnoses: diagnoses, source: .inProcess)
    }

    private func readDaemonSnapshot() -> Result? {
        let url = URL(fileURLWithPath: Self.daemonSnapshotPath)
        guard let data = try? Data(contentsOf: url, options: .uncached) else { return nil }
        guard let payload = try? decoder.decode(SnapshotPayload.self, from: data) else { return nil }
        guard payload.formatVersion == SnapshotPayload.currentFormatVersion else { return nil }
        guard Date().timeIntervalSince(payload.capturedAt) < Self.daemonFreshnessWindow else { return nil }
        return Result(
            snapshot: payload.snapshot,
            processes: payload.processes,
            diagnoses: payload.diagnoses,
            source: .daemon
        )
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
