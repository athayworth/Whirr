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

        var standalone: [Diagnosis] = []
        for rule in Self.allRules {
            if let diagnosis = rule.evaluate(core) {
                standalone.append(diagnosis)
            }
        }
        standalone.sort { $0.severity > $1.severity }

        var narratives: [Diagnosis] = []
        for narrative in Self.allNarratives {
            if let diagnosis = narrative.evaluate(core, diagnoses: standalone) {
                narratives.append(diagnosis)
            }
        }

        // Narratives lead, then standalone diagnoses ordered by severity.
        return narratives + standalone
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

    private static let allNarratives: [any NarrativeRule] = [
        BackupChokingForegroundNarrative(),
        MemorySwapSpiralNarrative(),
        ThermalThrottleAmplifierNarrative(),
        DiskMemoryContentionNarrative(),
        WindowServerHogNarrative(),
        SpotlightReindexNarrative(),
        DockerStrainNarrative()
    ]
}

private func formatMBps(_ bytesPerSec: UInt64) -> String {
    String(format: "%.0f MB/s", Double(bytesPerSec) / 1_048_576)
}

private func formatBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1.0 { return String(format: "%.1f GB", gb) }
    let mb = Double(bytes) / 1_048_576
    return String(format: "%.0f MB", mb)
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

/// A second-pass rule that sees the results of all standalone rules and
/// can synthesize a multi-signal explanation. Returns nil if no recognizable
/// pattern is present.
protocol NarrativeRule: Sendable {
    func evaluate(_ ctx: CoreContext, diagnoses: [Diagnosis]) -> Diagnosis?
}

private extension Array where Element == Diagnosis {
    func first(withTitle title: String) -> Diagnosis? {
        first { $0.title == title }
    }
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
        }
    }
}

struct OverloadedSystemRule: Rule {
    func evaluate(_ ctx: CoreContext) -> Diagnosis? {
        let load = ctx.snapshot.loadAverage.oneMinute
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
    // Spotlight (mds_stores, mds) is handled by SpotlightReindexNarrative,
    // which has the right user-facing framing for "your Mac is reindexing,
    // wait it out."
    private static let excluded: Set<String> = [
        "bzserv", "bztransmit", "bzfilelist", "bzbmenu",
        "backupd", "backupd-helper",
        "rsync", "restic", "borg",
        "mds_stores", "mds"
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
    /// Sample count required before we call something a sustained runaway.
    /// At the nominal 3-second sampling cadence this is ~15 seconds — long
    /// enough that brief compile/render spikes don't trip the rule.
    static let minSustainedSamples = 5
    /// Beyond this many sustained samples (~60 s) we promote to critical.
    static let extendedSustainedSamples = 20
    /// Approximate sampling cadence for converting sample counts to
    /// human-readable seconds in diagnoses. The sampler enforces a
    /// 1–60 s clamp; 3 s is the daemon's default and the menu bar app's.
    private static let assumedIntervalSeconds = 3

    func evaluate(_ ctx: CoreContext) -> Diagnosis? {
        let sustained = ctx.processes
            .filter { $0.sustainedHighCpuSamples >= Self.minSustainedSamples }
            .sorted { $0.cpuPercent > $1.cpuPercent }
        guard let worst = sustained.first else { return nil }

        let identity = displayCommandLine(for: worst)
        let durationSeconds = worst.sustainedHighCpuSamples * Self.assumedIntervalSeconds
        let severity: Severity =
            (worst.cpuPercent >= 200 || worst.sustainedHighCpuSamples >= Self.extendedSustainedSamples)
            ? .critical : .warning
        return Diagnosis(
            title: "\(worst.name) has been pegging CPU",
            detail: String(
                format: "%@ has been over 60%% CPU for the last %d seconds — currently %.0f%%, pid %d. If you weren't expecting this, the process may be stuck.",
                identity, durationSeconds, worst.cpuPercent, worst.pid
            ),
            severity: severity,
            culprits: [worst.name]
        )
    }

    private func displayCommandLine(for proc: ProcessSample) -> String {
        guard let cmd = proc.commandLine, !cmd.isEmpty, cmd != proc.name else {
            return proc.name
        }
        return cmd
    }
}

// MARK: - Narratives

/// The OG Whirr scenario: a backup is hammering disk while at least one
/// other subsystem is degraded. Backup reads compete with everything else
/// on the same SSD bandwidth, so the combination is worse than its parts.
struct BackupChokingForegroundNarrative: NarrativeRule {
    func evaluate(_ ctx: CoreContext, diagnoses: [Diagnosis]) -> Diagnosis? {
        guard let backup = diagnoses.first(withTitle: "Backup is using your system") else { return nil }

        let memoryTight = diagnoses.first(withTitle: "Memory is tight")
            ?? diagnoses.first(withTitle: "Memory is saturated")
        let swapping = diagnoses.first(withTitle: "System is swapping heavily")
        let thermal = diagnoses.first(withTitle: "CPU is throttling from heat")
            ?? diagnoses.first(withTitle: "CPU is critically hot")

        let secondarySignals = [memoryTight, swapping, thermal].compactMap { $0 }
        guard !secondarySignals.isEmpty else { return nil }

        let names = backup.culprits.sorted().joined(separator: ", ")
        var pieces: [String] = []
        if memoryTight != nil { pieces.append("memory is tight") }
        if swapping != nil { pieces.append("the system is swapping") }
        if thermal != nil { pieces.append("the CPU is throttling from heat") }
        let situation = joinNaturally(pieces)

        let severity = secondarySignals.map(\.severity).max() ?? backup.severity
        return Diagnosis(
            title: "Foreground apps will feel frozen",
            detail: "\(names) is hammering the disk while \(situation). "
                + "Backup reads compete with everything else on the SSD — pausing it is the fastest fix.",
            severity: severity,
            culprits: backup.culprits,
            kind: .narrative
        )
    }
}

/// Thermal throttle + a CPU-pegged process: the throttle is the bottleneck,
/// not the workload. Killing the runaway process won't bring back the lost
/// performance until the CPU cools off.
struct ThermalThrottleAmplifierNarrative: NarrativeRule {
    func evaluate(_ ctx: CoreContext, diagnoses: [Diagnosis]) -> Diagnosis? {
        let thermal = diagnoses.first(withTitle: "CPU is throttling from heat")
            ?? diagnoses.first(withTitle: "CPU is critically hot")
        guard let thermal else { return nil }
        let runaway = diagnoses.first { $0.title.hasSuffix("has been pegging CPU") }
        guard let runaway else { return nil }

        let culprit = runaway.culprits.first ?? "the top process"
        return Diagnosis(
            title: "Cooling matters more than killing right now",
            detail: "\(culprit) is pegging the CPU and the CPU is already throttling from heat — "
                + "the throttle is the bottleneck, not the workload. "
                + "Improving airflow (or pausing nearby heavy work) will recover more performance than force-quitting.",
            severity: thermal.severity,
            culprits: runaway.culprits,
            kind: .narrative
        )
    }
}

/// Heavy disk I/O combined with memory pressure: the system needs to page
/// from disk, but a busy process is eating the same SSD bandwidth that
/// macOS uses to read pages back in. Either side alone is annoying; together
/// they cause sustained stutter.
struct DiskMemoryContentionNarrative: NarrativeRule {
    func evaluate(_ ctx: CoreContext, diagnoses: [Diagnosis]) -> Diagnosis? {
        // Don't compete with more specific narratives: skip when Backup is
        // active, or when the underlying memory+swap condition that drives
        // MemorySwapSpiralNarrative is present.
        if diagnoses.first(withTitle: "Backup is using your system") != nil { return nil }
        let memorySaturatedAndSwapping =
            diagnoses.first(withTitle: "Memory is saturated") != nil
            && diagnoses.first(withTitle: "System is swapping heavily") != nil
        if memorySaturatedAndSwapping { return nil }

        guard let disk = diagnoses.first(withTitle: "Disk is busy") else { return nil }
        let memoryTight = diagnoses.first(withTitle: "Memory is tight")
            ?? diagnoses.first(withTitle: "Memory is saturated")
        guard let memoryTight else { return nil }

        let culprit = disk.culprits.first ?? "a process"
        return Diagnosis(
            title: "Disk and memory are fighting for the same SSD",
            detail: "\(culprit) is doing heavy disk I/O while memory pressure forces macOS to page from the same drive. "
                + "Closing \(culprit) or freeing RAM (either one) breaks the contention.",
            severity: max(disk.severity, memoryTight.severity),
            culprits: disk.culprits,
            kind: .narrative
        )
    }
}

/// Memory pressure + heavy swap = death spiral: every page-in trip costs SSD reads,
/// SSD reads compete with whatever the user is doing, slow foreground apps allocate
/// more memory, which causes more swap. Surface that the only fix is reducing memory load.
struct MemorySwapSpiralNarrative: NarrativeRule {
    func evaluate(_ ctx: CoreContext, diagnoses: [Diagnosis]) -> Diagnosis? {
        let saturated = diagnoses.first(withTitle: "Memory is saturated")
        let swapping = diagnoses.first(withTitle: "System is swapping heavily")
        guard saturated != nil, let swap = swapping else { return nil }

        // Don't compete with BackupChokingForegroundNarrative — it's a more specific story.
        if diagnoses.first(withTitle: "Backup is using your system") != nil { return nil }

        let topMemoryHog = ctx.processes
            .sorted { $0.memoryBytes > $1.memoryBytes }
            .first
        let suggestion: String
        if let hog = topMemoryHog, hog.memoryBytes > 0 {
            suggestion = String(
                format: "Top memory user is %@ at %@ — closing it (or its tabs/files) is the fastest win.",
                hog.name, formatBytes(hog.memoryBytes)
            )
        } else {
            suggestion = "Quitting unused apps is the only real fix — adding more swap just makes the disk read more."
        }

        return Diagnosis(
            title: "Memory + swap death spiral",
            detail: "RAM is full and macOS is paging hard to disk. \(suggestion)",
            severity: swap.severity,
            culprits: topMemoryHog.map { [$0.name] } ?? [],
            kind: .narrative
        )
    }
}

/// WindowServer eating CPU usually traces back to a graphics-heavy app
/// (Chrome with hundreds of tabs, an Electron app, video playback,
/// screen-recording software). The fastest fix is to identify and close
/// that app, not to look at WindowServer itself.
///
/// Only meaningful when the daemon is installed — WindowServer runs as
/// _windowserver, not the user, so unprivileged Whirr can't see its CPU%.
struct WindowServerHogNarrative: NarrativeRule {
    func evaluate(_ ctx: CoreContext, diagnoses: [Diagnosis]) -> Diagnosis? {
        guard let ws = ctx.processes.first(where: { $0.name == "WindowServer" }),
              ws.cpuPercent >= 50 else {
            return nil
        }
        let severity: Severity = ws.cpuPercent >= 100 ? .critical : .warning
        return Diagnosis(
            title: "Graphics layer is bottlenecking",
            detail: String(
                format: "WindowServer is at %.0f%% CPU — usually a heavy graphics app (Chrome/Safari with many tabs, an Electron app, fullscreen video, a screen recorder) is the cause. Closing or relaunching the heaviest one is the fastest fix.",
                ws.cpuPercent
            ),
            severity: severity,
            culprits: ["WindowServer"],
            kind: .narrative
        )
    }
}

/// Docker Desktop on macOS runs all containers inside a Linux VM (via
/// Apple's Virtualization framework). From the host's perspective the
/// entire fleet of containers shows up as a single Virtualization process
/// plus Docker's helper backends — you can see Docker is using resources,
/// but not WHICH container. The right next step is `docker stats`.
///
/// We detect Docker by the presence of `com.docker.backend` (Docker
/// Desktop's control plane). When that's present, we sum any other
/// processes that look like Docker: other com.docker.* binaries and any
/// Virtualization framework process (Docker's VM uses it).
///
/// On a machine where the user runs *only* Parallels/UTM and not Docker,
/// this rule stays quiet because `com.docker.backend` won't be running.
struct DockerStrainNarrative: NarrativeRule {
    private static let memoryWarnGB: Double = 4.0
    private static let memoryCritGB: Double = 8.0
    private static let cpuWarnPercent: Double = 50.0

    func evaluate(_ ctx: CoreContext, diagnoses: [Diagnosis]) -> Diagnosis? {
        guard ctx.processes.contains(where: { $0.name.hasPrefix("com.docker.") }) else {
            return nil
        }
        let dockerProcs = ctx.processes.filter { isDocker($0) }
        guard !dockerProcs.isEmpty else { return nil }

        let totalMemory = dockerProcs.reduce(UInt64(0)) { $0 &+ $1.memoryBytes }
        let totalCPU = dockerProcs.reduce(0.0) { $0 + $1.cpuPercent }
        let memoryGB = Double(totalMemory) / 1_073_741_824

        // Only surface a narrative when Docker is actually noticeable —
        // an idle Docker Desktop with no containers running might still
        // hold ~1 GB; don't pester about that.
        guard memoryGB >= Self.memoryWarnGB || totalCPU >= Self.cpuWarnPercent else {
            return nil
        }

        let severity: Severity = memoryGB >= Self.memoryCritGB ? .critical : .warning
        let processCount = dockerProcs.count
        return Diagnosis(
            title: "Docker is using significant resources",
            detail: String(
                format: "Docker is using %.1f GB and %.0f%% CPU across %d helper/VM processes. Per-container detail isn't visible from the host — run `docker stats` to see which container is responsible.",
                memoryGB, totalCPU, processCount
            ),
            severity: severity,
            culprits: dockerProcs.map(\.name),
            kind: .narrative
        )
    }

    private func isDocker(_ proc: ProcessSample) -> Bool {
        if proc.name.hasPrefix("com.docker.") { return true }
        // Virtualization framework processes are Docker's VM when Docker
        // is also running. False positive risk: someone using Parallels +
        // Docker would see Parallels VMs attributed to Docker too. For now
        // accept that tradeoff — most users running Docker aren't also
        // running Parallels.
        if proc.name.contains("Virtualization") { return true }
        if let cmd = proc.commandLine, cmd.contains("Virtualization.framework") { return true }
        return false
    }
}

/// Spotlight's mds_stores can dominate a Mac for 10–30 minutes during a
/// reindex (new volume mounted, large file move, system update). Surface
/// this as "wait it out" rather than as a generic disk/CPU diagnosis,
/// because the right action is to do nothing.
///
/// Only meaningful when the daemon is installed — mds and mds_stores run
/// as root.
struct SpotlightReindexNarrative: NarrativeRule {
    private static let mdsNames: Set<String> = ["mds_stores", "mds"]
    private static let activeIOThreshold: UInt64 = 20 * 1_048_576

    func evaluate(_ ctx: CoreContext, diagnoses: [Diagnosis]) -> Diagnosis? {
        let mds = ctx.processes.filter { Self.mdsNames.contains($0.name) }
        let active = mds.filter {
            $0.sustainedHighCpuSamples >= RunawayProcessRule.minSustainedSamples
                || $0.diskIOBytesPerSec >= Self.activeIOThreshold
        }
        guard !active.isEmpty else { return nil }

        let totalCPU = active.reduce(0.0) { $0 + $1.cpuPercent }
        let totalIO = active.reduce(UInt64(0)) { $0 &+ $1.diskIOBytesPerSec }

        let detail: String
        if totalIO >= Self.activeIOThreshold {
            detail = String(
                format: "Spotlight is rebuilding its index — mds_stores is reading from disk at %@. Expect 10–30 minutes of degraded performance until it finishes. Common triggers: new volume mounted, large file move, recent system update.",
                formatMBps(totalIO)
            )
        } else {
            detail = String(
                format: "Spotlight is reindexing — mds_stores is using %.0f%% CPU. Expect 10–30 minutes of degraded performance until it finishes. The right move is usually to wait it out, not to kill it (it'll just restart).",
                totalCPU
            )
        }
        return Diagnosis(
            title: "Spotlight is reindexing",
            detail: detail,
            severity: .warning,
            culprits: active.map(\.name),
            kind: .narrative
        )
    }
}

private func joinNaturally(_ pieces: [String]) -> String {
    switch pieces.count {
    case 0: return ""
    case 1: return pieces[0]
    case 2: return "\(pieces[0]) and \(pieces[1])"
    default:
        let head = pieces.dropLast().joined(separator: ", ")
        return "\(head), and \(pieces.last!)"
    }
}
