import Foundation

/// Who is behind a culprit: the app or service a process belongs to.
/// Findings that share an owner are one story (see StoryBuilder).
public enum CulpritOwner {
    public static func owner(of culprit: String, dockerRunning: Bool) -> String {
        if culprit.hasPrefix("com.docker.") { return "Docker" }
        // Docker Desktop runs containers in Apple's Virtualization VM; the
        // VM only counts as Docker while Docker's backend is running.
        if dockerRunning && culprit.contains("Virtualization") { return "Docker" }
        if culprit.hasPrefix("bz") { return "Backblaze" }
        if culprit.hasPrefix("backupd") { return "Time Machine" }
        return culprit
    }
}

/// Each owner's share of the Mac in one sample — the evidence for
/// "this owner is the biggest contributor".
public struct OwnerLoad: Sendable, Equatable {
    /// Owner → share of all CPU in use (0…1).
    public let cpuShare: [String: Double]
    /// Owner → share of total RAM (0…1).
    public let memoryShare: [String: Double]
    /// False when only this user's processes were visible, so CPU shares
    /// can't be trusted (other users' load is missing from the total).
    public let seesAllProcesses: Bool
    public let dockerRunning: Bool

    public init(cpuShare: [String: Double], memoryShare: [String: Double], seesAllProcesses: Bool,
                dockerRunning: Bool = false) {
        self.cpuShare = cpuShare
        self.memoryShare = memoryShare
        self.seesAllProcesses = seesAllProcesses
        self.dockerRunning = dockerRunning
    }

    public static let empty = OwnerLoad(cpuShare: [:], memoryShare: [:], seesAllProcesses: false)

    public static func compute(processes: [ProcessSample], totalRAM: UInt64,
                               describer: (ProcessSample) -> String, seesAllProcesses: Bool) -> OwnerLoad {
        let dockerRunning = processes.contains { $0.name == "com.docker.backend" }
        var cpu: [String: Double] = [:]
        var mem: [String: UInt64] = [:]
        for p in processes {
            // Name-based owners (Docker, backups) first; otherwise the
            // friendly name, which already folds helpers into their app.
            let byName = CulpritOwner.owner(of: p.name, dockerRunning: dockerRunning)
            let owner = byName != p.name ? byName : CulpritOwner.owner(of: describer(p), dockerRunning: dockerRunning)
            cpu[owner, default: 0] += p.cpuPercent
            mem[owner, default: 0] &+= p.memoryBytes
        }
        let totalCPU = cpu.values.reduce(0, +)
        return OwnerLoad(
            cpuShare: totalCPU > 0 ? cpu.mapValues { $0 / totalCPU } : [:],
            memoryShare: totalRAM > 0 ? mem.mapValues { Double($0) / Double(totalRAM) } : [:],
            seesAllProcesses: seesAllProcesses,
            dockerRunning: dockerRunning
        )
    }
}
