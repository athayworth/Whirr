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

    public init(
        pid: Int32,
        name: String,
        cpuPercent: Double,
        memoryBytes: UInt64,
        diskReadBytesPerSec: UInt64 = 0,
        diskWriteBytesPerSec: UInt64 = 0,
        commandLine: String? = nil,
        sustainedHighCpuSamples: Int = 0
    ) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.diskReadBytesPerSec = diskReadBytesPerSec
        self.diskWriteBytesPerSec = diskWriteBytesPerSec
        self.commandLine = commandLine
        self.sustainedHighCpuSamples = sustainedHighCpuSamples
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
    public let memoryFreeBytes: UInt64
    public let memoryPressure: MemoryPressure
    public let swapUsedBytes: UInt64
    public let thermalState: ThermalState
    public let loadAverage: LoadAverage

    public init(
        memoryUsedBytes: UInt64,
        memoryFreeBytes: UInt64,
        memoryPressure: MemoryPressure,
        swapUsedBytes: UInt64,
        thermalState: ThermalState,
        loadAverage: LoadAverage
    ) {
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryFreeBytes = memoryFreeBytes
        self.memoryPressure = memoryPressure
        self.swapUsedBytes = swapUsedBytes
        self.thermalState = thermalState
        self.loadAverage = loadAverage
    }

    public static let empty = SystemSnapshot(
        memoryUsedBytes: 0,
        memoryFreeBytes: 0,
        memoryPressure: .normal,
        swapUsedBytes: 0,
        thermalState: .nominal,
        loadAverage: .zero
    )
}

public enum MemoryPressure: Int, Sendable, Codable {
    case normal = 0
    case warning = 1
    case critical = 2
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
