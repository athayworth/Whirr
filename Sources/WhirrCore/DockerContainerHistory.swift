import Foundation

/// One sample of a single container's resource usage. Sampled at the same
/// cadence as the rest of the system (Preferences.samplingIntervalSeconds).
public struct DockerHistoryPoint: Sendable, Hashable, Codable {
    public let capturedAt: Date
    public let cpuPercent: Double
    public let memoryBytes: UInt64

    public init(capturedAt: Date, cpuPercent: Double, memoryBytes: UInt64) {
        self.capturedAt = capturedAt
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

/// Ring-buffer accumulator keyed by short container ID. Newest sample
/// last per slice. Containers are tombstoned (last sample retained, no
/// further appends) when they disappear from the live list so an
/// expanded detail panel doesn't lose its sparkline the moment the
/// container exits — and pruned entirely after a grace period so the
/// dict doesn't grow unbounded over a long session.
public struct DockerHistoryTracker: Sendable {
    /// Per-container history. Read by views; written by SystemMonitor.
    public private(set) var byContainer: [String: [DockerHistoryPoint]] = [:]

    /// Most-recent "seen" timestamp per container so we know when to drop
    /// stale entries. Map cleared when a container reappears.
    private var lastSeen: [String: Date] = [:]

    /// Cap per container. 360 points at 5-second sampling ≈ 30 minutes,
    /// matching the system history strip. At 16 B/sample × 360 ≈ 6 KB
    /// per container — fine for hundreds of containers.
    public static let perContainerCapacity = 360

    /// Drop containers that haven't been observed for this long. Long
    /// enough that a brief Docker daemon hiccup or compose restart
    /// doesn't lose history; short enough that exited containers stop
    /// taking up memory within a session.
    public static let staleAfter: TimeInterval = 5 * 60

    public init() {}

    /// Append the current snapshot for every visible container, prune any
    /// containers that exited more than `staleAfter` seconds ago.
    public mutating func record(_ containers: [DockerContainer], at now: Date) {
        for container in containers {
            var history = byContainer[container.id, default: []]
            history.append(DockerHistoryPoint(
                capturedAt: now,
                cpuPercent: container.cpuPercent,
                memoryBytes: container.memoryBytes
            ))
            if history.count > Self.perContainerCapacity {
                history.removeFirst(history.count - Self.perContainerCapacity)
            }
            byContainer[container.id] = history
            lastSeen[container.id] = now
        }
        prune(now: now)
    }

    private mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.staleAfter)
        for (id, seen) in lastSeen where seen < cutoff {
            byContainer.removeValue(forKey: id)
            lastSeen.removeValue(forKey: id)
        }
    }

    /// Convenience for the UI. Returns nil for unseen containers so
    /// callers can render a "no data yet" hint instead of an empty graph.
    public func history(for containerId: String) -> [DockerHistoryPoint]? {
        byContainer[containerId]
    }
}
