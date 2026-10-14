import Foundation

/// Takes a system snapshot + recent process samples and produces human-readable diagnoses.
/// Rules are pure functions of their inputs; ordering is by declared rule list.
public struct RulesEngine: Sendable {
    public let config: RulesConfig

    public init(config: RulesConfig = .default) {
        self.config = config
    }

    public func evaluate(
        snapshot: SystemSnapshot,
        processes: [ProcessSample],
        dockerContainers: [DockerContainer] = [],
        describer: @escaping @Sendable (ProcessSample) -> String = { $0.name },
        bundleIdentifier: @escaping @Sendable (ProcessSample) -> String? = { _ in nil },
        recentlyActiveBundleIds: Set<String> = []
    ) -> [Diagnosis] {
        let core = CoreContext(
            snapshot: snapshot,
            processes: processes,
            coreCount: ProcessInfo.processInfo.activeProcessorCount,
            dockerContainers: dockerContainers,
            describer: describer,
            bundleIdentifier: bundleIdentifier,
            recentlyActiveBundleIds: recentlyActiveBundleIds
        )

        var standalone: [Diagnosis] = []
        for rule in standaloneRules where rule.isEnabled {
            if let diagnosis = rule.evaluate(core) {
                standalone.append(diagnosis)
            }
        }
        standalone.sort { $0.severity > $1.severity }

        var narratives: [Diagnosis] = []
        for narrative in narrativeRules where narrative.isEnabled {
            if let diagnosis = narrative.evaluate(core, diagnoses: standalone) {
                narratives.append(diagnosis)
            }
        }

        // Narratives lead, then standalone diagnoses ordered by severity.
        return narratives + standalone
    }

    /// Per-tick allocation but the rule structs are cheap value types
    /// (each is a handful of stored properties). Keeps the engine
    /// `Sendable` without paying for a synchronization primitive on a
    /// shared rule list.
    private var standaloneRules: [any Rule] {
        [
            MemoryPressureRule(config: config.memoryPressure),
            SwapThrashingRule(config: config.swapThrashing),
            ThermalThrottleRule(config: config.thermalThrottle),
            OverloadedSystemRule(config: config.overloadedSystem),
            BackupHoggingRule(config: config.backupHogging),
            HighDiskIORule(config: config.highDiskIO),
            RunawayProcessRule(config: config.runawayProcess),
            LowDiskSpaceRule(config: config.lowDiskSpace)
        ]
    }

    private var narrativeRules: [any NarrativeRule] {
        [
            BackupChokingForegroundNarrative(config: config.backupChokingForeground),
            MemorySwapSpiralNarrative(config: config.memorySwapSpiral),
            ThermalThrottleAmplifierNarrative(config: config.thermalThrottleAmplifier),
            DiskMemoryContentionNarrative(config: config.diskMemoryContention),
            WindowServerHogNarrative(config: config.windowServerHog),
            SpotlightReindexNarrative(config: config.spotlightReindex),
            DockerStrainNarrative(config: config.dockerStrain),
            MemoryLeakNarrative(config: config.memoryLeak),
            IdleMemoryHogsNarrative(config: config.idleMemoryHogs)
        ]
    }
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

public struct CoreContext {
    public let snapshot: SystemSnapshot
    public let processes: [ProcessSample]
    public let coreCount: Int
    public let dockerContainers: [DockerContainer]
    /// Turns a `ProcessSample` into the name we should show the user.
    /// Default = raw process name so `RulesEngine.evaluate()` callers
    /// that don't pass a describer keep the prior behavior; the menu
    /// bar's pipeline passes `ProcessDescriptor.shared.friendlyName` so
    /// narratives say "Google Chrome" rather than "Google Chrome Helper
    /// (Renderer)".
    public let describer: @Sendable (ProcessSample) -> String
    /// Resolves a process's parent-app bundle identifier
    /// (CFBundleIdentifier — same value NSWorkspace uses for
    /// `frontmostApplication`). Returns nil for CLI daemons, kernel
    /// tasks, or processes we can't introspect. Used by rules that
    /// need to reconcile the process table with user-facing app
    /// identity — most importantly the idle-hogs narrative, which
    /// exempts apps the user actually focused recently.
    public let bundleIdentifier: @Sendable (ProcessSample) -> String?
    /// Bundle IDs of apps the user has focused within some recent
    /// window (30 min by default in the pipeline). A process whose
    /// parent app is in this set is considered "in use" regardless of
    /// its CPU idleness — a browser you read in without scrolling
    /// looks CPU-idle but isn't unused.
    public let recentlyActiveBundleIds: Set<String>

    public init(
        snapshot: SystemSnapshot,
        processes: [ProcessSample],
        coreCount: Int,
        dockerContainers: [DockerContainer] = [],
        describer: @escaping @Sendable (ProcessSample) -> String = { $0.name },
        bundleIdentifier: @escaping @Sendable (ProcessSample) -> String? = { _ in nil },
        recentlyActiveBundleIds: Set<String> = []
    ) {
        self.snapshot = snapshot
        self.processes = processes
        self.coreCount = coreCount
        self.dockerContainers = dockerContainers
        self.describer = describer
        self.bundleIdentifier = bundleIdentifier
        self.recentlyActiveBundleIds = recentlyActiveBundleIds
    }

    var topProcess: ProcessSample? { processes.first }

    func processes(named names: Set<String>) -> [ProcessSample] {
        processes.filter { names.contains($0.name) }
    }

    /// Convenience: friendly-name resolution + fallback to a default.
    func displayName(_ proc: ProcessSample?, fallback: String = "a process") -> String {
        guard let proc else { return fallback }
        return describer(proc)
    }
}

protocol Rule: Sendable {
    var isEnabled: Bool { get }
    func evaluate(_ ctx: CoreContext) -> Diagnosis?
}

/// A second-pass rule that sees the results of all standalone rules and
/// can synthesize a multi-signal explanation. Returns nil if no recognizable
/// pattern is present.
protocol NarrativeRule: Sendable {
    var isEnabled: Bool { get }
    func evaluate(_ ctx: CoreContext, diagnoses: [Diagnosis]) -> Diagnosis?
}

private extension Array where Element == Diagnosis {
    func first(withTitle title: String) -> Diagnosis? {
        first { $0.title == title }
    }
    /// Match by any of the given titles — needed since the swap rule can
    /// emit either "System is actively paging" (thrashing) or "Swap is
    /// holding old pages" (volume-only). Narrative rules that just care
    /// "is swap in the mix" use this; the death-spiral narrative uses
    /// the specific active-paging title alone.
    func first(withAnyTitle titles: [String]) -> Diagnosis? {
        let set = Set(titles)
        return first { set.contains($0.title) }
    }
}

/// Rule-emitted title constants that narrative rules cross-reference.
/// Kept as constants so a rename in one place produces a compile error
/// at every downstream match, not a silent behavioral regression.
enum DiagnosisTitles {
    static let memoryTight = "Memory is tight"
    static let memorySaturated = "Memory is saturated"
    static let swapActivelyPaging = "System is actively paging"
    static let swapVolumeOnly = "Swap is holding old pages"
    static let anySwap = [swapActivelyPaging, swapVolumeOnly]
    static let thermalWarning = "CPU is throttling from heat"
    static let thermalCritical = "CPU is critically hot"
    static let backupUsing = "Backup is using your system"
    static let diskBusy = "Disk is busy"
    static let runawaySuffix = "has been pegging CPU"
}

// MARK: - Rules

struct MemoryPressureRule: Rule {
    let config: MemoryPressureRuleConfig
    var isEnabled: Bool { config.enabled }
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

/// Distinguishes swap *volume* (macOS is holding pages on disk — happens
/// after any heavy session and stays put for hours) from swap *thrashing*
/// (macOS is actively paging in/out — the thing that actually slows the
/// system down). Prior versions conflated the two and cried wolf whenever
/// swap sat at ~2 GB after a heavy build. Now we say only what's true:
/// - active page-in rate → "actively thrashing" (real slowdown)
/// - volume alone → "using swap" (mildly informational)
struct SwapThrashingRule: Rule {
    let config: SwapThrashingRuleConfig
    var isEnabled: Bool { config.enabled }
    func evaluate(_ ctx: CoreContext) -> Diagnosis? {
        let gb = Double(ctx.snapshot.swapUsedBytes) / 1_073_741_824
        guard gb >= config.warningGB else { return nil }
        // Same gate as before — no point flagging stale compressed pages
        // when kernel says memory pressure is fine.
        guard ctx.snapshot.memoryPressure != .normal else { return nil }

        let rate = ctx.snapshot.pageInsPerSecond
        let isActivelyThrashing = rate >= config.thrashingPageInsPerSecond

        if isActivelyThrashing {
            // Actual thrashing: the paging is happening *now* and the user
            // is feeling it. This deserves the escalated language.
            let severity: Severity = gb >= config.criticalGB ? .critical : .warning
            return Diagnosis(
                title: "System is actively paging",
                detail: String(
                    format: "%.1f GB in swap and macOS is reading pages back at ~%d/s. This is what makes the machine feel sluggish — close something to reduce memory pressure.",
                    gb, Int(rate)
                ),
                severity: severity
            )
        }

        // Volume-only: pages are on disk but not moving. Informational,
        // not alarming — and never critical, because the user isn't
        // currently paying the disk cost that would justify "critical."
        return Diagnosis(
            title: "Swap is holding old pages",
            detail: String(
                format: "%.1f GB of memory is parked on disk, but macOS isn't actively moving pages in and out right now. This is a normal after-effect of a memory-heavy session — the number will drop as you close apps.",
                gb
            ),
            severity: .warning
        )
    }
}

struct ThermalThrottleRule: Rule {
    let config: ThermalThrottleRuleConfig
    var isEnabled: Bool { config.enabled }
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
    let config: OverloadedSystemRuleConfig
    var isEnabled: Bool { config.enabled }
    func evaluate(_ ctx: CoreContext) -> Diagnosis? {
        let load = ctx.snapshot.loadAverage.oneMinute
        let cores = Double(max(ctx.coreCount, 1))
        let ratio = load / cores
        guard ratio >= config.warningRatio else { return nil }
        return Diagnosis(
            title: "System is overloaded",
            detail: String(
                format: "Load average is %.1f on %d cores (%.1f× capacity). Too many processes are competing.",
                load, ctx.coreCount, ratio
            ),
            severity: ratio >= config.criticalRatio ? .critical : .warning
        )
    }
}

struct BackupHoggingRule: Rule {
    let config: BackupHoggingRuleConfig
    var isEnabled: Bool { config.enabled }

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
        let activeIOBytes = UInt64(config.activeIOMBs * 1_048_576)
        let active = ctx.processes(named: Self.backupProcessNames).filter {
            $0.cpuPercent >= config.activeCPUPercent
                || $0.diskIOBytesPerSec >= activeIOBytes
        }
        guard !active.isEmpty else { return nil }

        let totalCPU = active.reduce(0.0) { $0 + $1.cpuPercent }
        let totalIO = active.reduce(UInt64(0)) { $0 &+ $1.diskIOBytesPerSec }
        let names = active.map(\.name).sorted().joined(separator: ", ")

        let detail: String
        if totalIO >= activeIOBytes {
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

        // Promotion threshold for warning vs informational has historically
        // sat at 30 MB/s / 30% CPU. Leave this hardcoded for now — it's a
        // shape-of-output decision rather than a tunable knob.
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
    let config: HighDiskIORuleConfig
    var isEnabled: Bool { config.enabled }

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
        let warningBytes = UInt64(config.warningMBs * 1_048_576)
        let criticalBytes = UInt64(config.criticalMBs * 1_048_576)
        let heavy = ctx.processes
            .filter { !Self.excluded.contains($0.name) && $0.diskIOBytesPerSec >= warningBytes }
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
            severity: worst.diskIOBytesPerSec >= criticalBytes ? .critical : .warning,
            culprits: heavy.prefix(3).map(\.name)
        )
    }
}

struct LowDiskSpaceRule: Rule {
    let config: LowDiskSpaceRuleConfig
    var isEnabled: Bool { config.enabled }

    /// macOS does several costly things as free space drops — APFS metadata
    /// thrash, virtual memory eviction churn, Spotlight reindex deferral.
    /// Above ~85% used everything starts to feel sluggish; above ~95% the
    /// system actively struggles.
    func evaluate(_ ctx: CoreContext) -> Diagnosis? {
        let percentUsed = ctx.snapshot.rootDiskPercentUsed
        guard percentUsed >= config.warningPercentUsed else { return nil }
        let freeGB = Double(ctx.snapshot.rootDiskFreeBytes) / 1_073_741_824
        let severity: Severity = percentUsed >= config.criticalPercentUsed ? .critical : .warning
        return Diagnosis(
            title: "Disk is nearly full",
            detail: String(
                format: "Boot volume is %.0f%% full (%.1f GB free). macOS slows down as free space drops — clearing space speeds things up.",
                percentUsed, freeGB
            ),
            severity: severity
        )
    }
}

struct RunawayProcessRule: Rule {
    let config: RunawayProcessRuleConfig
    var isEnabled: Bool { config.enabled }

    /// Default sample counts kept as static so the test suite + narrative
    /// rules that also read these can stay pointed at one source of truth
    /// when running with the default config.
    static let minSustainedSamples = 5
    static let extendedSustainedSamples = 20
    /// Approximate sampling cadence for converting sample counts to
    /// human-readable seconds in diagnoses. The sampler enforces a
    /// 1–60 s clamp; 3 s is the daemon's default and the menu bar app's.
    private static let assumedIntervalSeconds = 3

    func evaluate(_ ctx: CoreContext) -> Diagnosis? {
        let sustained = ctx.processes
            .filter { $0.sustainedHighCpuSamples >= config.minSustainedSamples }
            .sorted { $0.cpuPercent > $1.cpuPercent }
        guard let worst = sustained.first else { return nil }

        let friendly = ctx.describer(worst)
        let identity = displayCommandLine(for: worst, friendly: friendly)
        let durationSeconds = worst.sustainedHighCpuSamples * Self.assumedIntervalSeconds
        let severity: Severity =
            (worst.cpuPercent >= 200 || worst.sustainedHighCpuSamples >= config.extendedSustainedSamples)
            ? .critical : .warning
        return Diagnosis(
            title: "\(friendly) has been pegging CPU",
            detail: String(
                format: "%@ has been over 60%% CPU for the last %d seconds — currently %.0f%%, pid %d. If you weren't expecting this, the process may be stuck.",
                identity, durationSeconds, worst.cpuPercent, worst.pid
            ),
            severity: severity,
            culprits: [friendly]
        )
    }

    /// Detail-line identity: prefer the full command line when it adds
    /// info (paths, script name), fall back to the friendly display
    /// name. Keeps the row header short (title = friendly name) and
    /// the detail rich (command line where useful).
    private func displayCommandLine(for proc: ProcessSample, friendly: String) -> String {
        guard let cmd = proc.commandLine, !cmd.isEmpty, cmd != proc.name else {
            return friendly
        }
        return cmd
    }
}

// MARK: - Narratives

/// The OG Whirr scenario: a backup is hammering disk while at least one
/// other subsystem is degraded. Backup reads compete with everything else
/// on the same SSD bandwidth, so the combination is worse than its parts.
struct BackupChokingForegroundNarrative: NarrativeRule {
    let config: NarrativeToggle
    var isEnabled: Bool { config.enabled }
    func evaluate(_ ctx: CoreContext, diagnoses: [Diagnosis]) -> Diagnosis? {
        guard let backup = diagnoses.first(withTitle: "Backup is using your system") else { return nil }

        let memoryTight = diagnoses.first(withTitle: DiagnosisTitles.memoryTight)
            ?? diagnoses.first(withTitle: DiagnosisTitles.memorySaturated)
        let swapping = diagnoses.first(withAnyTitle: DiagnosisTitles.anySwap)
        let thermal = diagnoses.first(withTitle: DiagnosisTitles.thermalWarning)
            ?? diagnoses.first(withTitle: DiagnosisTitles.thermalCritical)

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
            kind: .narrative,
            // Backup + the secondary signals it references are already
            // named in the detail line; hide their standalones.
            subsumes: [DiagnosisTitles.backupUsing] + secondarySignals.map(\.title)
        )
    }
}

/// Thermal throttle + a CPU-pegged process: the throttle is the bottleneck,
/// not the workload. Killing the runaway process won't bring back the lost
/// performance until the CPU cools off.
struct ThermalThrottleAmplifierNarrative: NarrativeRule {
    let config: NarrativeToggle
    var isEnabled: Bool { config.enabled }
    func evaluate(_ ctx: CoreContext, diagnoses: [Diagnosis]) -> Diagnosis? {
        let thermal = diagnoses.first(withTitle: DiagnosisTitles.thermalWarning)
            ?? diagnoses.first(withTitle: DiagnosisTitles.thermalCritical)
        guard let thermal else { return nil }
        let runaway = diagnoses.first { $0.title.hasSuffix(DiagnosisTitles.runawaySuffix) }
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
    let config: NarrativeToggle
    var isEnabled: Bool { config.enabled }
    func evaluate(_ ctx: CoreContext, diagnoses: [Diagnosis]) -> Diagnosis? {
        // Don't compete with more specific narratives: skip when Backup is
        // active, or when active-paging is happening (MemorySwapSpiral
        // covers the death-spiral case, and it's the strictly-worse story).
        if diagnoses.first(withTitle: DiagnosisTitles.backupUsing) != nil { return nil }
        let activelyPagingUnderSaturation =
            diagnoses.first(withTitle: DiagnosisTitles.memorySaturated) != nil
            && diagnoses.first(withTitle: DiagnosisTitles.swapActivelyPaging) != nil
        if activelyPagingUnderSaturation { return nil }

        guard let disk = diagnoses.first(withTitle: DiagnosisTitles.diskBusy) else { return nil }
        let memoryTight = diagnoses.first(withTitle: DiagnosisTitles.memoryTight)
            ?? diagnoses.first(withTitle: DiagnosisTitles.memorySaturated)
        guard let memoryTight else { return nil }

        let culprit = disk.culprits.first ?? "a process"
        return Diagnosis(
            title: "Disk and memory are fighting for the same SSD",
            detail: "\(culprit) is doing heavy disk I/O while memory pressure forces macOS to page from the same drive. "
                + "Closing \(culprit) or freeing RAM (either one) breaks the contention.",
            severity: max(disk.severity, memoryTight.severity),
            culprits: disk.culprits,
            kind: .narrative,
            // Both underlying rows are already named in this narrative
            // (disk-busy process + memory pressure). Suppress the
            // duplicates.
            subsumes: [DiagnosisTitles.diskBusy, DiagnosisTitles.memoryTight, DiagnosisTitles.memorySaturated]
        )
    }
}

/// Memory pressure + heavy swap = death spiral: every page-in trip costs SSD reads,
/// SSD reads compete with whatever the user is doing, slow foreground apps allocate
/// more memory, which causes more swap. Surface that the only fix is reducing memory load.
struct MemorySwapSpiralNarrative: NarrativeRule {
    let config: NarrativeToggle
    var isEnabled: Bool { config.enabled }
    func evaluate(_ ctx: CoreContext, diagnoses: [Diagnosis]) -> Diagnosis? {
        let saturated = diagnoses.first(withTitle: DiagnosisTitles.memorySaturated)
        // Only the *actively-paging* variant qualifies as a spiral. Volume
        // alone (post-heavy-session compressed pages sitting on disk) is
        // not a death spiral — no page-in traffic means no user-felt cost.
        let activelyPaging = diagnoses.first(withTitle: DiagnosisTitles.swapActivelyPaging)
        guard saturated != nil, activelyPaging != nil else { return nil }

        // Don't compete with BackupChokingForegroundNarrative — it's a more specific story.
        if diagnoses.first(withTitle: DiagnosisTitles.backupUsing) != nil { return nil }

        let topMemoryHog = ctx.processes
            .sorted { $0.memoryBytes > $1.memoryBytes }
            .first
        let suggestion: String
        if let hog = topMemoryHog, hog.memoryBytes > 0 {
            suggestion = String(
                format: "Top memory user is %@ at %@ — closing it (or its tabs/files) is the fastest win.",
                ctx.describer(hog), formatBytes(hog.memoryBytes)
            )
        } else {
            suggestion = "Quitting unused apps is the only real fix — adding more swap just makes the disk read more."
        }

        // Saturated memory is the gating signal here — by definition .critical
        // — so a swap-only-warning shouldn't downgrade a "death spiral" card.
        return Diagnosis(
            title: "Memory + swap death spiral",
            detail: "RAM is full and macOS is paging hard to disk. \(suggestion)",
            severity: .critical,
            culprits: topMemoryHog.map { [ctx.describer($0)] } ?? [],
            kind: .narrative,
            // The narrative already says "RAM is full and macOS is
            // paging" — surfacing the two underlying standalone rows
            // beneath it triples the count without adding information.
            subsumes: [DiagnosisTitles.memorySaturated, DiagnosisTitles.swapActivelyPaging]
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
    let config: WindowServerHogConfig
    var isEnabled: Bool { config.enabled }
    func evaluate(_ ctx: CoreContext, diagnoses: [Diagnosis]) -> Diagnosis? {
        guard let ws = ctx.processes.first(where: { $0.name == "WindowServer" }),
              ws.cpuPercent >= config.cpuPercentThreshold else {
            return nil
        }
        // Critical promotion ratio (2× the warning threshold) is hardcoded
        // — `100%` was the prior shape and tweaking it independently of
        // the warning threshold has never come up in practice.
        let severity: Severity = ws.cpuPercent >= (config.cpuPercentThreshold * 2) ? .critical : .warning
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
    let config: DockerStrainConfig
    var isEnabled: Bool { config.enabled }

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
        guard memoryGB >= config.memoryWarnGB || totalCPU >= config.cpuWarnPercent else {
            return nil
        }

        let severity: Severity = memoryGB >= config.memoryCritGB ? .critical : .warning

        // If we have per-container stats from the Docker socket, name the
        // heaviest container directly instead of telling the user to run
        // `docker stats` themselves.
        let detail: String
        if let worstContainer = ctx.dockerContainers.max(by: { $0.memoryBytes < $1.memoryBytes }) {
            let containerGB = Double(worstContainer.memoryBytes) / 1_073_741_824
            let containerMB = Double(worstContainer.memoryBytes) / 1_048_576
            let containerSize = containerGB >= 1.0
                ? String(format: "%.1f GB", containerGB)
                : String(format: "%.0f MB", containerMB)
            detail = String(
                format: "Docker is using %.1f GB and %.0f%% CPU across %d helper/VM processes. Heaviest container inside the VM: %@ at %@.",
                memoryGB, totalCPU, dockerProcs.count, worstContainer.name, containerSize
            )
        } else {
            detail = String(
                format: "Docker is using %.1f GB and %.0f%% CPU across %d helper/VM processes. Per-container detail isn't visible from the host — run `docker stats` to see which container is responsible.",
                memoryGB, totalCPU, dockerProcs.count
            )
        }

        return Diagnosis(
            title: "Docker is using significant resources",
            detail: detail,
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
    let config: SpotlightReindexConfig
    var isEnabled: Bool { config.enabled }

    private static let mdsNames: Set<String> = ["mds_stores", "mds"]

    func evaluate(_ ctx: CoreContext, diagnoses: [Diagnosis]) -> Diagnosis? {
        let activeIOBytes = UInt64(config.activeIOMBs * 1_048_576)
        let mds = ctx.processes.filter { Self.mdsNames.contains($0.name) }
        let active = mds.filter {
            $0.sustainedHighCpuSamples >= RunawayProcessRule.minSustainedSamples
                || $0.diskIOBytesPerSec >= activeIOBytes
        }
        guard !active.isEmpty else { return nil }

        let totalCPU = active.reduce(0.0) { $0 + $1.cpuPercent }
        let totalIO = active.reduce(UInt64(0)) { $0 &+ $1.diskIOBytesPerSec }

        let detail: String
        if totalIO >= activeIOBytes {
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

/// Detects the leak pattern: a single process's memory has grown
/// substantially over the last ~10 minutes. Distinct from "this process
/// is big" (already covered by Top by memory and MemorySwapSpiral) —
/// the signal here is the *trajectory*. A process that's been at 5 GB
/// for an hour is annoying but probably what it does. A process that
/// has gone from 5 GB to 7 GB in 10 minutes is almost certainly leaking.
///
/// Restarting the process is the right action and what the diagnosis
/// suggests. We don't fire below a 1 GB current footprint — small
/// processes growing don't warrant a card.
struct MemoryLeakNarrative: NarrativeRule {
    let config: MemoryLeakConfig
    var isEnabled: Bool { config.enabled }

    /// Static defaults kept for tests that reference them directly.
    static let growthThresholdBytes: Int64 = 500 * 1_048_576
    static let memoryFloorBytes: UInt64 = 1_073_741_824
    static let criticalGrowthThresholdBytes: Int64 = 2 * 1_073_741_824

    func evaluate(_ ctx: CoreContext, diagnoses: [Diagnosis]) -> Diagnosis? {
        let growthBytes = Int64(config.growthThresholdMB * 1_048_576)
        let floorBytes = UInt64(config.memoryFloorMB * 1_048_576)
        let critBytes = Int64(config.criticalGrowthThresholdMB * 1_048_576)
        let leakers = ctx.processes
            .compactMap { proc -> (proc: ProcessSample, delta: Int64)? in
                guard let delta = proc.memoryDelta10MinBytes,
                      delta >= growthBytes,
                      proc.memoryBytes >= floorBytes
                else { return nil }
                return (proc, delta)
            }
            .sorted { $0.delta > $1.delta }
        guard let worst = leakers.first else { return nil }

        let currentBytes = worst.proc.memoryBytes
        let formerBytes = max(Int64(0), Int64(currentBytes) - worst.delta)
        let currentGB = Double(currentBytes) / 1_073_741_824
        let formerGB = Double(formerBytes) / 1_073_741_824
        let deltaGB = Double(worst.delta) / 1_073_741_824

        let severity: Severity = worst.delta >= critBytes ? .critical : .warning
        let name = ctx.describer(worst.proc)
        return Diagnosis(
            title: "\(name) memory has been growing",
            detail: String(
                format: "%@ went from %.1f GB to %.1f GB (+%.1f GB) in the last 10 minutes. This is the leak pattern — restarting it would recover that memory.",
                name, formerGB, currentGB, deltaGB
            ),
            severity: severity,
            culprits: [name],
            kind: .narrative
        )
    }
}

/// Surfaces big processes that haven't done CPU work in a while —
/// answers "am I even using this?" for the dev environment case: half-
/// remembered local servers, an IDE left open, browser tabs you forgot.
/// Stays silent unless the *combined* recoverable memory is meaningful.
///
/// Filters by a memory floor (we don't flag a 200 MB process) and a
/// minimum idle streak (don't flag something that just paused for a
/// few seconds), then aggregates so the user sees one card with N
/// candidates rather than N separate diagnoses.
struct IdleMemoryHogsNarrative: NarrativeRule {
    let config: IdleMemoryHogsConfig
    var isEnabled: Bool { config.enabled }

    /// Defaults kept as statics for the test suite + downstream readers
    /// (e.g., MenuBarView's "idle 5m" badge calculation).
    static let memoryFloorBytes: UInt64 = 500 * 1_048_576
    static let minIdleSamples = 100
    static let combinedMemoryThresholdBytes: UInt64 = 2 * 1_073_741_824
    /// Approximate sampling cadence for converting sample counts to
    /// minutes in the user-facing message.
    private static let assumedIntervalSeconds = 3

    func evaluate(_ ctx: CoreContext, diagnoses: [Diagnosis]) -> Diagnosis? {
        let floorBytes = UInt64(config.memoryFloorMB * 1_048_576)
        let combinedThresholdBytes = UInt64(config.combinedMemoryThresholdMB * 1_048_576)
        let candidates = ctx.processes
            .filter {
                $0.memoryBytes >= floorBytes
                && $0.sustainedIdleSamples >= config.minIdleSamples
                // Exempt apps the user has recently focused. CPU-idle
                // ≠ unused for GUI apps: a browser sitting on a static
                // page reads as idle even though the user is reading
                // it. NSWorkspace's frontmost history (sampled each
                // tick) lets us reconcile "process CPU" with "user
                // attention" — if the parent-app bundle ID was
                // frontmost within the tracker's lookback window, the
                // process stays off the unused list.
                && !isRecentlyActiveApp($0, ctx: ctx)
            }
            .sorted { $0.memoryBytes > $1.memoryBytes }
        guard !candidates.isEmpty else { return nil }

        let combined = candidates.reduce(UInt64(0)) { $0 &+ $1.memoryBytes }
        guard combined >= combinedThresholdBytes else { return nil }

        let combinedGB = Double(combined) / 1_073_741_824
        let topThree = candidates.prefix(3)
        // Longest streak in the candidate set — phrased as a maximum, not a
        // minimum, because using "≥ X" with the max of the group overstates
        // what's true for the smaller candidates.
        let longestIdleMinutes = (candidates.map(\.sustainedIdleSamples).max() ?? 0)
            * Self.assumedIntervalSeconds / 60

        let pieces = topThree.map { proc -> String in
            "\(ctx.describer(proc)) (\(formatMemory(proc.memoryBytes)))"
        }
        let extra = candidates.count > 3 ? ", +\(candidates.count - 3) more" : ""
        let detail = String(
            format: "%@%@ look unused (longest idle: %d min). Closing them would free roughly %.1f GB. Skip any servers you want kept warm.",
            pieces.joined(separator: ", "), extra, longestIdleMinutes, combinedGB
        )
        return Diagnosis(
            title: "Big processes that look unused",
            detail: detail,
            severity: .ok,
            culprits: candidates.map { ctx.describer($0) },
            kind: .narrative
        )
    }

    private func formatMemory(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    private func isRecentlyActiveApp(_ proc: ProcessSample, ctx: CoreContext) -> Bool {
        guard !ctx.recentlyActiveBundleIds.isEmpty else { return false }
        guard let bundleId = ctx.bundleIdentifier(proc) else { return false }
        return ctx.recentlyActiveBundleIds.contains(bundleId)
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
