import Foundation

public enum Severity: Int, Comparable, Sendable {
    case ok = 0
    case warning = 1
    case critical = 2

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct Diagnosis: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable {
        case standalone
        /// A diagnosis that explains how several standalone diagnoses interact
        /// — rendered as a headline above the individual items.
        case narrative
    }

    public let id = UUID()
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
        self.title = title
        self.detail = detail
        self.severity = severity
        self.culprits = culprits
        self.kind = kind
    }
}

public struct ProcessSample: Identifiable, Hashable, Sendable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    public let diskReadBytesPerSec: UInt64
    public let diskWriteBytesPerSec: UInt64

    public init(
        pid: Int32,
        name: String,
        cpuPercent: Double,
        memoryBytes: UInt64,
        diskReadBytesPerSec: UInt64 = 0,
        diskWriteBytesPerSec: UInt64 = 0
    ) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.diskReadBytesPerSec = diskReadBytesPerSec
        self.diskWriteBytesPerSec = diskWriteBytesPerSec
    }

    public var diskIOBytesPerSec: UInt64 {
        diskReadBytesPerSec &+ diskWriteBytesPerSec
    }
}

public struct SystemSnapshot: Sendable {
    public let memoryUsedBytes: UInt64
    public let memoryFreeBytes: UInt64
    public let memoryPressure: MemoryPressure
    public let swapUsedBytes: UInt64
    public let thermalState: ProcessInfo.ThermalState
    public let loadAverage: (Double, Double, Double)

    public init(
        memoryUsedBytes: UInt64,
        memoryFreeBytes: UInt64,
        memoryPressure: MemoryPressure,
        swapUsedBytes: UInt64,
        thermalState: ProcessInfo.ThermalState,
        loadAverage: (Double, Double, Double)
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
        loadAverage: (0, 0, 0)
    )
}

public enum MemoryPressure: Sendable {
    case normal, warning, critical
}
