import Foundation

public enum Severity: Int, Comparable, Sendable, Codable {
    case ok = 0
    case warning = 1
    case critical = 2

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct Diagnosis: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case standalone
        /// A diagnosis that explains how several standalone diagnoses interact
        /// — rendered as a headline above the individual items.
        case narrative
    }

    public let id: UUID
    public let title: String
    public let detail: String
    public let severity: Severity
    public let culprits: [String]
    public let kind: Kind
    /// Titles of standalone diagnoses this one *explains*. Narrative
    /// rules use this to tell the UI "if I'm showing, hide these lower-
    /// level rows — I already explain what they were saying." Prevents
    /// the "Memory + swap death spiral" + "Memory is saturated" +
    /// "System is actively paging" pile-up where three rows narrate
    /// the same underlying state at three levels of abstraction.
    public let subsumes: [String]
    /// Problem vs. note — see `Diagnosis.Tier`. Assigned by
    /// `FindingClassifier`; rules leave the default.
    public let tier: Tier
    /// Sidebar section this finding belongs to.
    public let area: Area
    /// The one fix the UI should offer, if any.
    public let action: SuggestedAction?

    public init(
        title: String,
        detail: String,
        severity: Severity,
        culprits: [String] = [],
        kind: Kind = .standalone,
        subsumes: [String] = [],
        tier: Tier = .problem,
        area: Area = .mac,
        action: SuggestedAction? = nil
    ) {
        self.init(id: UUID(), title: title, detail: detail, severity: severity, culprits: culprits,
                  kind: kind, subsumes: subsumes, tier: tier, area: area, action: action)
    }

    private init(
        id: UUID, title: String, detail: String, severity: Severity, culprits: [String],
        kind: Kind, subsumes: [String], tier: Tier, area: Area, action: SuggestedAction?
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.severity = severity
        self.culprits = culprits
        self.kind = kind
        self.subsumes = subsumes
        self.tier = tier
        self.area = area
        self.action = action
    }

    /// Same finding (same `id`) with presentation fields replaced.
    public func classified(tier: Tier, area: Area, action: SuggestedAction?) -> Diagnosis {
        Diagnosis(id: id, title: title, detail: detail, severity: severity, culprits: culprits,
                  kind: kind, subsumes: subsumes, tier: tier, area: area, action: action)
    }

    // Backward-compatible decoding for daemon payloads written before
    // `subsumes` existed — missing key decodes to []. Wire format
    // version is not bumped for the additive change.
    private enum CodingKeys: String, CodingKey {
        case id, title, detail, severity, culprits, kind, subsumes, tier, area, action
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.detail = try c.decode(String.self, forKey: .detail)
        self.severity = try c.decode(Severity.self, forKey: .severity)
        self.culprits = try c.decodeIfPresent([String].self, forKey: .culprits) ?? []
        self.kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .standalone
        self.subsumes = try c.decodeIfPresent([String].self, forKey: .subsumes) ?? []
        self.tier = try c.decodeIfPresent(Tier.self, forKey: .tier) ?? .problem
        self.area = try c.decodeIfPresent(Area.self, forKey: .area) ?? .mac
        self.action = try c.decodeIfPresent(SuggestedAction.self, forKey: .action)
    }
}

public struct ProcessSample: Identifiable, Hashable, Sendable, Codable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let cpuPercent: Double
    /// "Real memory" footprint — what Activity Monitor's "Memory" column
    /// shows. Resident pages plus pages held in the page compressor.
    /// This is a better proxy for memory responsibility than bare resident
    /// size, which under-counts on a compressed/swapped system.
    public let memoryBytes: UInt64
    public let diskReadBytesPerSec: UInt64
    public let diskWriteBytesPerSec: UInt64
    /// Full command line including arguments (truncated). Nil when the
    /// caller couldn't read it — typically because the process is owned by
    /// another user and we're not root.
    public let commandLine: String?
    /// Number of consecutive recent samples in which this process exceeded
    /// the high-CPU threshold. Multiply by the sampling interval (3s
    /// nominally) to convert to seconds of sustained load.
    public let sustainedHighCpuSamples: Int
    /// Number of consecutive recent samples in which this process was below
    /// the idle-CPU threshold. Used to identify big-but-quiescent processes
    /// (dev servers you left running, IDEs you forgot about) that the user
    /// might want to close to recover RAM.
    public let sustainedIdleSamples: Int
    /// Memory change over ~10 minutes (current minus value 10 min ago).
    /// Positive = growing (possible leak), negative = shrinking, nil =
    /// not enough history yet (process younger than 10 min from the
    /// sampler's perspective, or sampler just started).
    public let memoryDelta10MinBytes: Int64?
    /// Full path to the executable. Used by the safety classifier to
    /// distinguish system processes (under /System, /usr) from user apps
    /// (under /Applications, ~/Library). Nil when we couldn't read it
    /// (other-user process when not root).
    public let executablePath: String?
    /// Effective UID of the process. 0 = root. Nil when unreadable.
    public let userId: UInt32?
    /// Parent process ID. Useful for helper-process identification —
    /// "Arc Helper" with parent "Arc" → kill the parent, not the helper.
    public let parentPid: Int32?

    public init(
        pid: Int32,
        name: String,
        cpuPercent: Double,
        memoryBytes: UInt64,
        diskReadBytesPerSec: UInt64 = 0,
        diskWriteBytesPerSec: UInt64 = 0,
        commandLine: String? = nil,
        sustainedHighCpuSamples: Int = 0,
        sustainedIdleSamples: Int = 0,
        memoryDelta10MinBytes: Int64? = nil,
        executablePath: String? = nil,
        userId: UInt32? = nil,
        parentPid: Int32? = nil
    ) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.diskReadBytesPerSec = diskReadBytesPerSec
        self.diskWriteBytesPerSec = diskWriteBytesPerSec
        self.commandLine = commandLine
        self.sustainedHighCpuSamples = sustainedHighCpuSamples
        self.sustainedIdleSamples = sustainedIdleSamples
        self.memoryDelta10MinBytes = memoryDelta10MinBytes
        self.executablePath = executablePath
        self.userId = userId
        self.parentPid = parentPid
    }

    public var diskIOBytesPerSec: UInt64 {
        diskReadBytesPerSec &+ diskWriteBytesPerSec
    }

    private enum CodingKeys: String, CodingKey {
        case pid, name, cpuPercent, memoryBytes, diskReadBytesPerSec, diskWriteBytesPerSec
        case commandLine, sustainedHighCpuSamples, sustainedIdleSamples, memoryDelta10MinBytes
        case executablePath, userId, parentPid
    }

    // Hand-rolled decode so payloads from an older installed daemon —
    // which predate fields like `sustainedIdleSamples` — still decode.
    // A required-key miss here fails the whole snapshot and silently
    // drops the app back to in-process sampling.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.pid = try c.decode(Int32.self, forKey: .pid)
        self.name = try c.decode(String.self, forKey: .name)
        self.cpuPercent = try c.decode(Double.self, forKey: .cpuPercent)
        self.memoryBytes = try c.decode(UInt64.self, forKey: .memoryBytes)
        self.diskReadBytesPerSec = try c.decodeIfPresent(UInt64.self, forKey: .diskReadBytesPerSec) ?? 0
        self.diskWriteBytesPerSec = try c.decodeIfPresent(UInt64.self, forKey: .diskWriteBytesPerSec) ?? 0
        self.commandLine = try c.decodeIfPresent(String.self, forKey: .commandLine)
        self.sustainedHighCpuSamples = try c.decodeIfPresent(Int.self, forKey: .sustainedHighCpuSamples) ?? 0
        self.sustainedIdleSamples = try c.decodeIfPresent(Int.self, forKey: .sustainedIdleSamples) ?? 0
        self.memoryDelta10MinBytes = try c.decodeIfPresent(Int64.self, forKey: .memoryDelta10MinBytes)
        self.executablePath = try c.decodeIfPresent(String.self, forKey: .executablePath)
        self.userId = try c.decodeIfPresent(UInt32.self, forKey: .userId)
        self.parentPid = try c.decodeIfPresent(Int32.self, forKey: .parentPid)
    }
}

public struct LoadAverage: Hashable, Sendable, Codable {
    public let oneMinute: Double
    public let fiveMinute: Double
    public let fifteenMinute: Double

    public init(oneMinute: Double, fiveMinute: Double, fifteenMinute: Double) {
        self.oneMinute = oneMinute
        self.fiveMinute = fiveMinute
        self.fifteenMinute = fifteenMinute
    }

    public static let zero = LoadAverage(oneMinute: 0, fiveMinute: 0, fifteenMinute: 0)
}

public struct SystemSnapshot: Sendable, Codable {
    public let memoryUsedBytes: UInt64
    /// Bytes the kernel considers reclaimable: `free + inactive + speculative`.
    /// Activity Monitor calls this "Available." The JSON wire key is kept as
    /// `memoryFreeBytes` for backward compatibility with existing daemon
    /// snapshots — see CodingKeys.
    public let memoryAvailableBytes: UInt64
    public let memoryPressure: MemoryPressure
    public let swapUsedBytes: UInt64
    public let thermalState: ThermalState
    public let loadAverage: LoadAverage
    /// Free bytes on the volume backing `/` (the boot volume). Low free
    /// disk space is a real and common slowdown cause that doesn't show up
    /// in memory/CPU stats. Defaults to 0 in the empty snapshot.
    public let rootDiskFreeBytes: UInt64
    public let rootDiskTotalBytes: UInt64
    /// Kernel page-ins per second — a page-in is macOS reading a
    /// swapped-out page back from disk. This is what "thrashing" actually
    /// means, distinct from `swapUsedBytes` (which can sit high for hours
    /// after peak with zero active paging). Zero when the sampler hasn't
    /// yet observed two ticks to diff against. Optional-on-decode so old
    /// daemon snapshots that predate the field decode cleanly as 0.
    public let pageInsPerSecond: Double

    public init(
        memoryUsedBytes: UInt64,
        memoryAvailableBytes: UInt64,
        memoryPressure: MemoryPressure,
        swapUsedBytes: UInt64,
        thermalState: ThermalState,
        loadAverage: LoadAverage,
        rootDiskFreeBytes: UInt64 = 0,
        rootDiskTotalBytes: UInt64 = 0,
        pageInsPerSecond: Double = 0
    ) {
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryAvailableBytes = memoryAvailableBytes
        self.memoryPressure = memoryPressure
        self.swapUsedBytes = swapUsedBytes
        self.thermalState = thermalState
        self.loadAverage = loadAverage
        self.rootDiskFreeBytes = rootDiskFreeBytes
        self.rootDiskTotalBytes = rootDiskTotalBytes
        self.pageInsPerSecond = pageInsPerSecond
    }

    private enum CodingKeys: String, CodingKey {
        case memoryUsedBytes
        case memoryAvailableBytes = "memoryFreeBytes"
        case memoryPressure
        case swapUsedBytes
        case thermalState
        case loadAverage
        case rootDiskFreeBytes
        case rootDiskTotalBytes
        case pageInsPerSecond
    }

    // Hand-rolled decode so new fields fall back to 0 when reading a
    // snapshot written by an older daemon that predates them. Keeps the
    // wire format additive-compatible — no bump of SnapshotPayload.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.memoryUsedBytes = try c.decode(UInt64.self, forKey: .memoryUsedBytes)
        self.memoryAvailableBytes = try c.decode(UInt64.self, forKey: .memoryAvailableBytes)
        self.memoryPressure = try c.decode(MemoryPressure.self, forKey: .memoryPressure)
        self.swapUsedBytes = try c.decode(UInt64.self, forKey: .swapUsedBytes)
        self.thermalState = try c.decode(ThermalState.self, forKey: .thermalState)
        self.loadAverage = try c.decode(LoadAverage.self, forKey: .loadAverage)
        self.rootDiskFreeBytes = try c.decodeIfPresent(UInt64.self, forKey: .rootDiskFreeBytes) ?? 0
        self.rootDiskTotalBytes = try c.decodeIfPresent(UInt64.self, forKey: .rootDiskTotalBytes) ?? 0
        self.pageInsPerSecond = try c.decodeIfPresent(Double.self, forKey: .pageInsPerSecond) ?? 0
    }

    public static let empty = SystemSnapshot(
        memoryUsedBytes: 0,
        memoryAvailableBytes: 0,
        memoryPressure: .normal,
        swapUsedBytes: 0,
        thermalState: .nominal,
        loadAverage: .zero
    )

    public var rootDiskPercentUsed: Double {
        guard rootDiskTotalBytes > 0 else { return 0 }
        let used = rootDiskTotalBytes &- rootDiskFreeBytes
        return Double(used) / Double(rootDiskTotalBytes) * 100.0
    }
}

public enum MemoryPressure: Int, Sendable, Codable, Comparable {
    case normal = 0
    case warning = 1
    case critical = 2

    public static func < (lhs: MemoryPressure, rhs: MemoryPressure) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Codable mirror of `ProcessInfo.ThermalState`. We don't use the Foundation
/// type directly because it's an Obj-C-bridged NSEnum and Codable
/// conformance is awkward to extend; pinning our own raw values also keeps
/// the wire format stable across macOS versions.
public enum ThermalState: Int, Sendable, Codable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public init(_ ns: ProcessInfo.ThermalState) {
        switch ns {
        case .nominal:  self = .nominal
        case .fair:     self = .fair
        case .serious:  self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }
}

/// Plain-language "can I keep working?" summary. The rules engine tells
/// the user *what's wrong*; this tells them *whether they need to act*.
/// Pure function of the current snapshot + top-hog processes — no state,
/// no smoothing. Computed once per tick alongside diagnoses.
public struct HeadroomAssessment: Sendable, Codable, Hashable {
    public enum Verdict: String, Sendable, Codable {
        /// Plenty of room. Keep going.
        case comfortable
        /// Working fine now but a big new thing (docker up, video export,
        /// heavy build) would tip you into pressure.
        case tight
        /// System is already under real pressure; something to close.
        case pressed
    }

    /// Best plain-language answer to "how much slack do I have left?"
    /// For memory that's available bytes (what macOS can hand out without
    /// paging). Zero when we don't yet have a valid reading.
    public let availableMemoryBytes: UInt64
    public let totalMemoryBytes: UInt64
    public let verdict: Verdict
    /// One sentence for the top of the menu — e.g., "Safe to keep going."
    public let headline: String
    /// One sentence of context — e.g., "Chrome is holding 4.2 GB."
    public let context: String
    /// The single process that would recover the most memory if closed,
    /// if there's a meaningful one to name.
    public let topHogName: String?
    public let topHogBytes: UInt64?

    public init(
        availableMemoryBytes: UInt64,
        totalMemoryBytes: UInt64,
        verdict: Verdict,
        headline: String,
        context: String,
        topHogName: String? = nil,
        topHogBytes: UInt64? = nil
    ) {
        self.availableMemoryBytes = availableMemoryBytes
        self.totalMemoryBytes = totalMemoryBytes
        self.verdict = verdict
        self.headline = headline
        self.context = context
        self.topHogName = topHogName
        self.topHogBytes = topHogBytes
    }
}

/// A Harbr project — the subset of Harbr's on-disk config that Whirr uses
/// for process attribution + the Dev-servers section. Whirr reads
/// `~/.harbr/config.json` at startup; Harbr's own model has many more
/// fields, but Whirr only cares about identity + port. Extra JSON keys
/// are ignored so we're forward-compatible with Harbr's evolution.
public struct HarbrProject: Sendable, Codable, Hashable, Identifiable {
    public var id: Int { port }
    public let name: String
    public let port: Int
    public let group: String?

    public init(name: String, port: Int, group: String? = nil) {
        self.name = name
        self.port = port
        self.group = group
    }
}

/// Runtime state of a Harbr project as observed by Whirr. Combines the
/// static config (name/port) with what Whirr found in the process table
/// or via a local port probe — is anything listening, and if so what's
/// its CPU/memory footprint. Rendered by HarbrSection in the menu.
public struct HarbrProjectStatus: Sendable, Hashable, Identifiable {
    public var id: Int { project.port }
    public let project: HarbrProject
    public let isRunning: Bool
    /// Process holding the port. Nil when nothing's listening (Whirr will
    /// then show the row as stopped) or when Whirr couldn't attribute
    /// the port to a process it also saw in the sampler output.
    public let pid: Int32?
    public let processName: String?
    public let cpuPercent: Double?
    public let memoryBytes: UInt64?

    public init(
        project: HarbrProject,
        isRunning: Bool,
        pid: Int32? = nil,
        processName: String? = nil,
        cpuPercent: Double? = nil,
        memoryBytes: UInt64? = nil
    ) {
        self.project = project
        self.isRunning = isRunning
        self.pid = pid
        self.processName = processName
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

/// A diagnosis paired with time-based state — how long it's been firing,
/// which direction it's trending, whether the user snoozed it. The UI
/// consumes this rather than raw Diagnosis so the "on for 40 min · stable"
/// badge, snooze button, and dimmed-when-snoozed styling all share the
/// same source of truth.
public struct DiagnosisContext: Sendable, Hashable, Identifiable {
    public enum Trend: String, Sendable, Codable {
        case improving
        case stable
        case worsening
    }

    public var id: UUID { diagnosis.id }
    public let diagnosis: Diagnosis
    /// When the diagnosis (by title) first started firing continuously.
    /// Reset once the condition clears.
    public let firstSeenAt: Date
    /// Seconds since firstSeenAt at the tick this context was built.
    public let durationSeconds: Int
    public let trend: Trend
    /// True while the user's snooze on this title is active. UI hides
    /// snoozed contexts from the primary list + counts them out of the
    /// header severity + suppresses notifications.
    public let isSnoozed: Bool
    /// Wall-clock time the snooze expires (nil when not snoozed).
    public let snoozedUntil: Date?
    /// Highest severity reached in the current streak. Ranking by this
    /// rather than the instantaneous severity keeps a long-running
    /// problem that dips warning↔critical from flapping the headline.
    public let peakSeverity: Severity

    public init(
        diagnosis: Diagnosis,
        firstSeenAt: Date,
        durationSeconds: Int,
        trend: Trend,
        isSnoozed: Bool = false,
        snoozedUntil: Date? = nil,
        peakSeverity: Severity? = nil
    ) {
        self.peakSeverity = max(peakSeverity ?? diagnosis.severity, diagnosis.severity)
        self.diagnosis = diagnosis
        self.firstSeenAt = firstSeenAt
        self.durationSeconds = durationSeconds
        self.trend = trend
        self.isSnoozed = isSnoozed
        self.snoozedUntil = snoozedUntil
    }
}

/// One point in the rolling history that the daemon maintains for the
/// "what's been happening lately" view. Intentionally light — we keep
/// system-level signals only, not per-process state, because per-process
/// would blow up the history file size at the sampling rate we want.
public struct TrendPoint: Codable, Sendable, Hashable {
    public let capturedAt: Date
    public let memoryPressure: MemoryPressure
    public let memoryUsedBytes: UInt64
    public let swapUsedBytes: UInt64
    public let loadOneMinute: Double
    public let worstSeverity: Severity

    public init(
        capturedAt: Date,
        memoryPressure: MemoryPressure,
        memoryUsedBytes: UInt64,
        swapUsedBytes: UInt64,
        loadOneMinute: Double,
        worstSeverity: Severity
    ) {
        self.capturedAt = capturedAt
        self.memoryPressure = memoryPressure
        self.memoryUsedBytes = memoryUsedBytes
        self.swapUsedBytes = swapUsedBytes
        self.loadOneMinute = loadOneMinute
        self.worstSeverity = worstSeverity
    }
}

/// Rolling history of recent samples, persisted alongside the snapshot
/// when the daemon is installed. Newest points last.
public struct TrendHistory: Codable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let points: [TrendPoint]

    public init(points: [TrendPoint]) {
        self.formatVersion = Self.currentFormatVersion
        self.points = points
    }
}

/// Wire format written by `whirr-sampler` and consumed by the menu bar app.
/// `formatVersion` is incremented on breaking schema changes; readers that
/// see an unknown version should fall back to in-process sampling rather
/// than guess at the payload.
public struct SnapshotPayload: Codable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let capturedAt: Date
    public let snapshot: SystemSnapshot
    public let processes: [ProcessSample]
    public let diagnoses: [Diagnosis]

    public init(
        capturedAt: Date,
        snapshot: SystemSnapshot,
        processes: [ProcessSample],
        diagnoses: [Diagnosis]
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.capturedAt = capturedAt
        self.snapshot = snapshot
        self.processes = processes
        self.diagnoses = diagnoses
    }
}
