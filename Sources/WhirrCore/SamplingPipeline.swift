import Foundation

/// One tick of "what's going on" data. Either freshly sampled in-process
/// or read from the daemon's snapshot file, then run through the same
/// rules engine either way.
public actor SamplingPipeline {
    public struct Result: Sendable {
        public let snapshot: SystemSnapshot
        public let processes: [ProcessSample]
        public let diagnoses: [Diagnosis]
        public let history: [TrendPoint]
        public let source: Source

        public enum Source: Sendable { case daemon, inProcess }

        public init(
            snapshot: SystemSnapshot,
            processes: [ProcessSample],
            diagnoses: [Diagnosis],
            history: [TrendPoint],
            source: Source
        ) {
            self.snapshot = snapshot
            self.processes = processes
            self.diagnoses = diagnoses
            self.history = history
            self.source = source
        }
    }

    /// File written by `whirr-sampler` when the launchd daemon is installed.
    /// If this file exists and is fresh, we use it (covers root processes);
    /// otherwise we fall back to in-process sampling (works without the daemon).
    public static let defaultSnapshotPath = "/Library/Application Support/Whirr/snapshot.json"
    public static let defaultHistoryPath = "/Library/Application Support/Whirr/history.json"

    /// How stale the daemon's file can be before we treat it as gone.
    /// Tied to the daemon's 3-second interval with comfortable slack.
    public static let defaultFreshnessWindow: TimeInterval = 10

    private let snapshotPath: String
    private let historyPath: String
    private let freshnessWindow: TimeInterval
    /// Injectable for tests so freshness checks are deterministic.
    private let clock: @Sendable () -> Date

    private let processSampler = ProcessSampler()
    private let rules = RulesEngine()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(
        snapshotPath: String = SamplingPipeline.defaultSnapshotPath,
        historyPath: String = SamplingPipeline.defaultHistoryPath,
        freshnessWindow: TimeInterval = SamplingPipeline.defaultFreshnessWindow,
        clock: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.snapshotPath = snapshotPath
        self.historyPath = historyPath
        self.freshnessWindow = freshnessWindow
        self.clock = clock
    }

    public func tick(containers: [DockerContainer] = []) -> Result {
        if let fromDaemon = readDaemonSnapshot(containers: containers) {
            return fromDaemon
        }
        let snapshot = SystemSampler.sample()
        let processes = processSampler.sample()
        let diagnoses = rules.evaluate(
            snapshot: snapshot,
            processes: processes,
            dockerContainers: containers
        )
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

    private func readDaemonSnapshot(containers: [DockerContainer]) -> Result? {
        let url = URL(fileURLWithPath: snapshotPath)
        guard let data = try? Data(contentsOf: url, options: .uncached) else { return nil }
        guard let payload = try? decoder.decode(SnapshotPayload.self, from: data) else { return nil }
        guard payload.formatVersion == SnapshotPayload.currentFormatVersion else { return nil }
        guard clock().timeIntervalSince(payload.capturedAt) < freshnessWindow else { return nil }
        // Re-run the rules engine on the daemon's snapshot + processes rather
        // than trusting payload.diagnoses. The daemon's rule set is whatever
        // shipped with the installed binary, which may be stale relative to
        // the app's; this way rule changes ship with the next app build.
        // Container stats come from the menu bar (user-mode); pass them in.
        let diagnoses = rules.evaluate(
            snapshot: payload.snapshot,
            processes: payload.processes,
            dockerContainers: containers
        )
        return Result(
            snapshot: payload.snapshot,
            processes: payload.processes,
            diagnoses: diagnoses,
            history: readDaemonHistory(),
            source: .daemon
        )
    }

    private func readDaemonHistory() -> [TrendPoint] {
        let url = URL(fileURLWithPath: historyPath)
        guard let data = try? Data(contentsOf: url, options: .uncached) else { return [] }
        guard let history = try? decoder.decode(TrendHistory.self, from: data),
              history.formatVersion == TrendHistory.currentFormatVersion else {
            return []
        }
        return history.points
    }
}
