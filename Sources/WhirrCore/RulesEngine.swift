import Foundation

/// Takes a system snapshot + recent process samples and produces human-readable diagnoses.
/// Rules are pure functions of their inputs; ordering is by declared rule list.
public struct RulesEngine: Sendable {
    public init() {}

    public func evaluate(snapshot: SystemSnapshot, processes: [ProcessSample]) -> [Diagnosis] {
        let core = CoreContext(
            snapshot: snapshot,
            processes: processes,
            coreCount: ProcessInfo.processInfo.activeProcessorCount
        )

        var results: [Diagnosis] = []
        for rule in Self.allRules {
            if let diagnosis = rule.evaluate(core) {
                results.append(diagnosis)
            }
        }
        return results.sorted { $0.severity > $1.severity }
    }

    private static let allRules: [any Rule] = [
        MemoryPressureRule(),
        SwapThrashingRule(),
        ThermalThrottleRule(),
        OverloadedSystemRule(),
        BackupHoggingRule(),
        RunawayProcessRule()
    ]
}

struct CoreContext {
    let snapshot: SystemSnapshot
    let processes: [ProcessSample]
    let coreCount: Int

    var topProcess: ProcessSample? { processes.first }

    func processes(named names: Set<String>) -> [ProcessSample] {
        processes.filter { names.contains($0.name) }
    }
}

protocol Rule: Sendable {
    func evaluate(_ ctx: CoreContext) -> Diagnosis?
}

// MARK: - Rules

struct MemoryPressureRule: Rule {
    func evaluate(_ ctx: CoreContext) -> Diagnosis? {
        switch ctx.snapshot.memoryPressure {
        case .critical:
            return Diagnosis(
                title: "Memory is saturated",
                detail: "Very little free RAM left. macOS is compressing pages to keep up — apps will stutter.",
                severity: .critical
            )
        case .warning:
            return Diagnosis(
                title: "Memory is tight",
                detail: "Free memory is running low. Quitting unused apps will help.",
                severity: .warning
            )
        case .normal:
            return nil
        }
    }
}

struct SwapThrashingRule: Rule {
    func evaluate(_ ctx: CoreContext) -> Diagnosis? {
        let gb = Double(ctx.snapshot.swapUsedBytes) / 1_073_741_824
        guard gb >= 2.0 else { return nil }
        return Diagnosis(
            title: "System is swapping heavily",
            detail: String(format: "%.1f GB of swap in use — disk is being treated as RAM, which is much slower.", gb),
            severity: gb >= 6.0 ? .critical : .warning
        )
    }
}

struct ThermalThrottleRule: Rule {
    func evaluate(_ ctx: CoreContext) -> Diagnosis? {
        switch ctx.snapshot.thermalState {
        case .critical:
            return Diagnosis(
                title: "CPU is critically hot",
                detail: "macOS is aggressively throttling to cool down. Performance will be much lower than normal.",
                severity: .critical
            )
        case .serious:
            return Diagnosis(
                title: "CPU is throttling from heat",
                detail: "Performance is being held back to cool down. Check fan/airflow.",
                severity: .warning
            )
        case .fair, .nominal:
            return nil
        @unknown default:
            return nil
        }
    }
}

struct OverloadedSystemRule: Rule {
    func evaluate(_ ctx: CoreContext) -> Diagnosis? {
        let load = ctx.snapshot.loadAverage.0
        let cores = Double(max(ctx.coreCount, 1))
        let ratio = load / cores
        guard ratio >= 1.5 else { return nil }
        return Diagnosis(
            title: "System is overloaded",
            detail: String(
                format: "Load average is %.1f on %d cores (%.1f× capacity). Too many processes are competing.",
                load, ctx.coreCount, ratio
            ),
            severity: ratio >= 3.0 ? .critical : .warning
        )
    }
}

struct BackupHoggingRule: Rule {
    private static let backupProcessNames: Set<String> = [
        "bzserv",
        "bztransmit",
        "bzfilelist",
        "bzbmenu",
        "backupd",          // Time Machine
        "backupd-helper",
        "rsync",
        "restic",
        "borg"
    ]

    func evaluate(_ ctx: CoreContext) -> Diagnosis? {
        let active = ctx.processes(named: Self.backupProcessNames).filter { $0.cpuPercent >= 5.0 }
        guard !active.isEmpty else { return nil }
        let totalCPU = active.reduce(0.0) { $0 + $1.cpuPercent }
        let names = active.map(\.name).sorted().joined(separator: ", ")
        return Diagnosis(
            title: "Backup is using your system",
            detail: String(format: "%@ is using %.0f%% CPU. Pause it temporarily to free up resources.", names, totalCPU),
            severity: totalCPU >= 30 ? .warning : .ok,
            culprits: active.map(\.name)
        )
    }
}

struct RunawayProcessRule: Rule {
    func evaluate(_ ctx: CoreContext) -> Diagnosis? {
        guard let worst = ctx.topProcess, worst.cpuPercent >= 80 else { return nil }
        return Diagnosis(
            title: "\(worst.name) is using a lot of CPU",
            detail: String(format: "%.0f%% CPU on pid %d. If you weren't expecting this, the process may be stuck.", worst.cpuPercent, worst.pid),
            severity: worst.cpuPercent >= 200 ? .critical : .warning,
            culprits: [worst.name]
        )
    }
}
