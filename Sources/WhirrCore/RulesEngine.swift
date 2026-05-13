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
        HighDiskIORule(),
        RunawayProcessRule()
    ]
}

private func formatMBps(_ bytesPerSec: UInt64) -> String {
    String(format: "%.0f MB/s", Double(bytesPerSec) / 1_048_576)
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

    // Backup processes are I/O-bound, so a sustained read rate matters more
    // than CPU%. 5 MB/s is well above idle housekeeping but well below an
    // active scan/upload.
    private static let activeIOThreshold: UInt64 = 5 * 1_048_576
    private static let activeCPUThreshold: Double = 5.0

    func evaluate(_ ctx: CoreContext) -> Diagnosis? {
        let active = ctx.processes(named: Self.backupProcessNames).filter {
            $0.cpuPercent >= Self.activeCPUThreshold || $0.diskIOBytesPerSec >= Self.activeIOThreshold
        }
        guard !active.isEmpty else { return nil }

        let totalCPU = active.reduce(0.0) { $0 + $1.cpuPercent }
        let totalIO = active.reduce(UInt64(0)) { $0 &+ $1.diskIOBytesPerSec }
        let names = active.map(\.name).sorted().joined(separator: ", ")

        let detail: String
        if totalIO >= Self.activeIOThreshold {
            detail = String(
                format: "%@ is reading/writing %@ (%.0f%% CPU). Pause it temporarily to free up disk and memory.",
                names, formatMBps(totalIO), totalCPU
            )
        } else {
            detail = String(
                format: "%@ is using %.0f%% CPU. Pause it temporarily to free up resources.",
                names, totalCPU
            )
        }

        let severity: Severity = (totalIO >= 30 * 1_048_576 || totalCPU >= 30) ? .warning : .ok
        return Diagnosis(
            title: "Backup is using your system",
            detail: detail,
            severity: severity,
            culprits: active.map(\.name)
        )
    }
}

struct HighDiskIORule: Rule {
    // 50 MB/s sustained from a single process is enough to noticeably
    // contend with foreground work on an internal SSD; 200 MB/s pegs it.
    private static let warningThreshold: UInt64 = 50 * 1_048_576
    private static let criticalThreshold: UInt64 = 200 * 1_048_576

    // Backup processes are handled by BackupHoggingRule — don't double-fire.
    private static let excluded: Set<String> = [
        "bzserv", "bztransmit", "bzfilelist", "bzbmenu",
        "backupd", "backupd-helper",
        "rsync", "restic", "borg"
    ]

    func evaluate(_ ctx: CoreContext) -> Diagnosis? {
        let heavy = ctx.processes
            .filter { !Self.excluded.contains($0.name) && $0.diskIOBytesPerSec >= Self.warningThreshold }
            .sorted { $0.diskIOBytesPerSec > $1.diskIOBytesPerSec }
        guard let worst = heavy.first else { return nil }

        let readsMostly = worst.diskReadBytesPerSec >= worst.diskWriteBytesPerSec
        let verb = readsMostly ? "reading" : "writing"
        return Diagnosis(
            title: "Disk is busy",
            detail: String(
                format: "%@ is %@ %@ from disk. Heavy I/O can make the whole system feel sluggish.",
                worst.name, verb, formatMBps(worst.diskIOBytesPerSec)
            ),
            severity: worst.diskIOBytesPerSec >= Self.criticalThreshold ? .critical : .warning,
            culprits: heavy.prefix(3).map(\.name)
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
