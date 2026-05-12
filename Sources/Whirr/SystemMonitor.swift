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
        case .critical: return "exclamationmark.triangle.fill"
        case .warning:  return "gauge.with.dots.needle.67percent"
        case .ok:       return "gauge.with.dots.needle.33percent"
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
    }

    private let processSampler = ProcessSampler()
    private let rules = RulesEngine()

    func tick() -> Result {
        let snapshot = SystemSampler.sample()
        let processes = processSampler.sample()
        let diagnoses = rules.evaluate(snapshot: snapshot, processes: processes)
        return Result(snapshot: snapshot, processes: processes, diagnoses: diagnoses)
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
