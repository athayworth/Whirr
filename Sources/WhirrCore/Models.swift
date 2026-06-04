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

    public init(
        title: String,
        detail: String,
        severity: Severity,
        culprits: [String] = [],
        kind: Kind = .standalone
    ) {
        self.id = UUID()
        self.title = title
        self.detail = detail
        self.severity = severity
        self.culprits = culprits
        self.kind = kind
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

    public init(
        memoryUsedBytes: UInt64,
        memoryAvailableBytes: UInt64,
        memoryPressure: MemoryPressure,
        swapUsedBytes: UInt64,
        thermalState: ThermalState,
        loadAverage: LoadAverage,
        rootDiskFreeBytes: UInt64 = 0,
        rootDiskTotalBytes: UInt64 = 0
    ) {
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryAvailableBytes = memoryAvailableBytes
        self.memoryPressure = memoryPressure
        self.swapUsedBytes = swapUsedBytes
        self.thermalState = thermalState
        self.loadAverage = loadAverage
        self.rootDiskFreeBytes = rootDiskFreeBytes
        self.rootDiskTotalBytes = rootDiskTotalBytes
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
