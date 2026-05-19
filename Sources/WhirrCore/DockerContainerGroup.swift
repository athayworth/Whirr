import Foundation

/// Groups containers by Docker Compose project (or "ungrouped" for
/// containers started outside of Compose). Each group surfaces aggregate
/// totals so the menu bar can show one summary row per project with
/// the individual containers underneath. Pure function — testable
/// without a live Docker daemon.
public struct DockerContainerGroup: Identifiable, Sendable, Hashable {
    /// Group title — the Compose project name, or nil for the ungrouped
    /// bucket. Identifiers fall back to "" so SwiftUI ForEach is happy
    /// either way.
    public let project: String?
    public let members: [DockerContainer]

    public var id: String { project ?? "" }
    public var totalMemoryBytes: UInt64 {
        members.reduce(UInt64(0)) { $0 &+ $1.memoryBytes }
    }
    public var totalCpuPercent: Double {
        members.reduce(0.0) { $0 + $1.cpuPercent }
    }

    /// Groups containers by Compose project. Groups are sorted by total
    /// memory (largest first); members within each group also by memory.
    /// The ungrouped bucket (nil project) sorts to the bottom regardless
    /// of its size — Compose projects are the more interesting story.
    public static func group(_ containers: [DockerContainer]) -> [DockerContainerGroup] {
        let buckets = Dictionary(grouping: containers, by: \.composeProject)
        return buckets.map { project, members in
            DockerContainerGroup(
                project: project,
                members: members.sorted { $0.memoryBytes > $1.memoryBytes }
            )
        }
        .sorted { lhs, rhs in
            // Ungrouped always last.
            if (lhs.project == nil) != (rhs.project == nil) {
                return lhs.project != nil
            }
            return lhs.totalMemoryBytes > rhs.totalMemoryBytes
        }
    }
}
