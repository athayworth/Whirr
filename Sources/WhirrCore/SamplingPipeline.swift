import Foundation

/// One tick of "what's going on" data. Either freshly sampled in-process
/// or read from the daemon's snapshot file, then run through the same
/// rules engine either way — plus headroom + duration-annotated contexts
/// + Harbr project attribution, all layered on top by the pipeline itself.
/// Health of the root sampler daemon's snapshot file, as seen this tick.
/// `.undecodable` almost always means the installed daemon binary is
/// older than the app and writes a payload shape the app can't read —
/// the UI surfaces it so that failure isn't silent.
public enum DaemonStatus: Sendable, Equatable {
    case fresh, stale, undecodable, absent
}

public actor SamplingPipeline {
    public struct Result: Sendable {
        public let snapshot: SystemSnapshot
        public let processes: [ProcessSample]
        /// Per-diagnosis "on for X, trend Y" annotation. Callers that
        /// don't need duration use `diagnoses`.
        public let diagnosisContexts: [DiagnosisContext]
        /// "Can I keep going?" summary — one line the UI puts at top of
        /// the menu, above the diagnoses list.
        public let headroom: HeadroomAssessment
        public let history: [TrendPoint]
        /// Harbr project statuses. Empty when Harbr's config isn't
        /// present (Harbr not installed, or user hasn't added any
        /// projects yet).
        public let harbrStatuses: [HarbrProjectStatus]
        public let source: Source
        public let daemonStatus: DaemonStatus

        public enum Source: Sendable { case daemon, inProcess }

        /// Convenience: just the diagnoses, without the context wrapper.
        public var diagnoses: [Diagnosis] { diagnosisContexts.map(\.diagnosis) }

        public init(
            snapshot: SystemSnapshot,
            processes: [ProcessSample],
            diagnosisContexts: [DiagnosisContext],
            headroom: HeadroomAssessment,
            history: [TrendPoint],
            harbrStatuses: [HarbrProjectStatus],
            source: Source,
            daemonStatus: DaemonStatus = .absent
        ) {
            self.snapshot = snapshot
            self.processes = processes
            self.diagnosisContexts = diagnosisContexts
            self.headroom = headroom
            self.history = history
            self.harbrStatuses = harbrStatuses
            self.source = source
            self.daemonStatus = daemonStatus
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
    private let systemSampler = SystemSampler()
    private let rules: RulesEngine
    private var durationTracker = DiagnosisDurationTracker()
    private let harbrConfigReader: HarbrConfigReader
    /// Persisted log of closed incidents — read by the Insights charts
    /// in Settings. Written on rising-edge → falling-edge transitions
    /// via `DiagnosisDurationTracker.annotate` returning `closedIncidents`.
    public let incidentLog: IncidentLog

    /// Port-listening cache. Refreshed every N ticks by re-probing every
    /// known Harbr port; between refreshes we use the last-known value.
    /// This keeps the tick cost bounded (at most ~1 second every N ticks
    /// worst-case, spread across ports one-by-one).
    private var portListeningCache: [Int: Bool] = [:]
    private var ticksUntilPortRefresh: Int = 0
    /// Number of ticks between full port re-probes. At the default 3 s
    /// tick, this is a ~15-second cadence — dev servers don't come up
    /// or shut down inside a 15-second window often enough for the
    /// finer granularity to matter.
    private let portProbeEveryTicks: Int = 5

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(
        snapshotPath: String = SamplingPipeline.defaultSnapshotPath,
        historyPath: String = SamplingPipeline.defaultHistoryPath,
        freshnessWindow: TimeInterval = SamplingPipeline.defaultFreshnessWindow,
        clock: @Sendable @escaping () -> Date = { Date() },
        rulesConfig: RulesConfig = .default,
        harbrConfigReader: HarbrConfigReader = HarbrConfigReader(),
        incidentLog: IncidentLog = IncidentLog()
    ) {
        self.snapshotPath = snapshotPath
        self.historyPath = historyPath
        self.freshnessWindow = freshnessWindow
        self.clock = clock
        self.rules = RulesEngine(config: rulesConfig)
        self.harbrConfigReader = harbrConfigReader
        self.incidentLog = incidentLog
    }

    public func tick(
        containers: [DockerContainer] = [],
        recentlyActiveBundleIds: Set<String> = []
    ) -> Result {
        let (fromDaemon, daemonStatus) = readDaemonSnapshot(
            containers: containers,
            recentlyActiveBundleIds: recentlyActiveBundleIds
        )
        if let fromDaemon { return fromDaemon }
        let snapshot = systemSampler.sample()
        let processes = processSampler.sample()
        let diagnoses = rules.evaluate(
            snapshot: snapshot,
            processes: processes,
            dockerContainers: containers,
            describer: { ProcessDescriptor.shared.friendlyName(for: $0) },
            bundleIdentifier: { ProcessDescriptor.shared.bundleIdentifier(for: $0) },
            recentlyActiveBundleIds: recentlyActiveBundleIds
        )
        return buildResult(
            snapshot: snapshot,
            processes: processes,
            diagnoses: diagnoses,
            history: [],
            source: .inProcess,
            daemonStatus: daemonStatus
        )
    }

    private func readDaemonSnapshot(
        containers: [DockerContainer],
        recentlyActiveBundleIds: Set<String>
    ) -> (Result?, DaemonStatus) {
        let url = URL(fileURLWithPath: snapshotPath)
        guard let data = try? Data(contentsOf: url, options: .uncached) else { return (nil, .absent) }
        guard let payload = try? decoder.decode(SnapshotPayload.self, from: data),
              payload.formatVersion == SnapshotPayload.currentFormatVersion else {
            return (nil, .undecodable)
        }
        guard clock().timeIntervalSince(payload.capturedAt) < freshnessWindow else { return (nil, .stale) }
        // Re-run the rules engine on the daemon's snapshot + processes rather
        // than trusting payload.diagnoses. The daemon's rule set is whatever
        // shipped with the installed binary, which may be stale relative to
        // the app's; this way rule changes ship with the next app build.
        let diagnoses = rules.evaluate(
            snapshot: payload.snapshot,
            processes: payload.processes,
            dockerContainers: containers,
            describer: { ProcessDescriptor.shared.friendlyName(for: $0) },
            bundleIdentifier: { ProcessDescriptor.shared.bundleIdentifier(for: $0) },
            recentlyActiveBundleIds: recentlyActiveBundleIds
        )
        return (buildResult(
            snapshot: payload.snapshot,
            processes: payload.processes,
            diagnoses: diagnoses,
            history: readDaemonHistory(),
            source: .daemon,
            daemonStatus: .fresh
        ), .fresh)
    }

    private func buildResult(
        snapshot: SystemSnapshot,
        processes: [ProcessSample],
        diagnoses: [Diagnosis],
        history: [TrendPoint],
        source: Result.Source,
        daemonStatus: DaemonStatus
    ) -> Result {
        let now = clock()
        let annotation = durationTracker.annotate(diagnoses, now: now)
        // Persist any incidents that just closed. The log handles its
        // own retention + purge; we don't need to bound writes here.
        for incident in annotation.closedIncidents {
            incidentLog.record(incident)
        }
        // Pass the swap rule's page-in threshold to the headroom
        // assessor so a single knob controls "actively paging" across
        // both the rule engine and the headline verdict.
        let headroom = HeadroomAssessor.assess(
            snapshot: snapshot,
            processes: processes,
            pageInThreshold: rules.config.swapThrashing.thrashingPageInsPerSecond
        )
        let harbrStatuses = evaluateHarbr(processes: processes)
        return Result(
            snapshot: snapshot,
            processes: processes,
            diagnosisContexts: annotation.contexts,
            headroom: headroom,
            history: history,
            harbrStatuses: harbrStatuses,
            source: source,
            daemonStatus: daemonStatus
        )
    }

    private func evaluateHarbr(processes: [ProcessSample]) -> [HarbrProjectStatus] {
        let projects = harbrConfigReader.projects()
        guard !projects.isEmpty else {
            portListeningCache.removeAll(keepingCapacity: false)
            ticksUntilPortRefresh = 0
            return []
        }
        refreshPortCacheIfDue(for: projects)
        return HarbrAttribution.statuses(
            projects: projects,
            processes: processes,
            portListening: { [portListeningCache] port in portListeningCache[port] ?? false }
        )
    }

    private func refreshPortCacheIfDue(for projects: [HarbrProject]) {
        if ticksUntilPortRefresh > 0 {
            ticksUntilPortRefresh -= 1
            return
        }
        var next: [Int: Bool] = [:]
        for project in projects {
            next[project.port] = HarbrAttribution.defaultPortListening(project.port)
        }
        portListeningCache = next
        ticksUntilPortRefresh = portProbeEveryTicks
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
