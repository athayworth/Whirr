import Foundation

/// User-editable rules engine configuration. Lives at
/// `~/Library/Application Support/Whirr/rules.json` and is loaded once
/// at app launch (changes take effect on next restart).
///
/// Each nested config uses `decodeIfPresent(...) ?? default` so a partial
/// config like `{"swapThrashing": {"warningGB": 8}}` works — every
/// missing key falls back to the embedded default, which matches the
/// behavior that shipped before the config existed. Adding a new rule's
/// config is a non-breaking change for existing config files.
public struct RulesConfig: Codable, Sendable, Equatable {
    /// Bumped on breaking schema changes (e.g., renamed key, removed
    /// rule). Loader rejects unknown versions and falls back to the
    /// embedded defaults rather than guess.
    public static let currentFormatVersion = 1

    public let formatVersion: Int

    // Standalone rules
    public let memoryPressure: MemoryPressureRuleConfig
    public let swapThrashing: SwapThrashingRuleConfig
    public let thermalThrottle: ThermalThrottleRuleConfig
    public let overloadedSystem: OverloadedSystemRuleConfig
    public let backupHogging: BackupHoggingRuleConfig
    public let highDiskIO: HighDiskIORuleConfig
    public let lowDiskSpace: LowDiskSpaceRuleConfig
    public let runawayProcess: RunawayProcessRuleConfig

    // Narratives
    public let backupChokingForeground: NarrativeToggle
    public let memorySwapSpiral: NarrativeToggle
    public let thermalThrottleAmplifier: NarrativeToggle
    public let diskMemoryContention: NarrativeToggle
    public let windowServerHog: WindowServerHogConfig
    public let spotlightReindex: SpotlightReindexConfig
    public let dockerStrain: DockerStrainConfig
    public let memoryLeak: MemoryLeakConfig
    public let idleMemoryHogs: IdleMemoryHogsConfig

    public init(
        formatVersion: Int = currentFormatVersion,
        memoryPressure: MemoryPressureRuleConfig = .init(),
        swapThrashing: SwapThrashingRuleConfig = .init(),
        thermalThrottle: ThermalThrottleRuleConfig = .init(),
        overloadedSystem: OverloadedSystemRuleConfig = .init(),
        backupHogging: BackupHoggingRuleConfig = .init(),
        highDiskIO: HighDiskIORuleConfig = .init(),
        lowDiskSpace: LowDiskSpaceRuleConfig = .init(),
        runawayProcess: RunawayProcessRuleConfig = .init(),
        backupChokingForeground: NarrativeToggle = .init(),
        memorySwapSpiral: NarrativeToggle = .init(),
        thermalThrottleAmplifier: NarrativeToggle = .init(),
        diskMemoryContention: NarrativeToggle = .init(),
        windowServerHog: WindowServerHogConfig = .init(),
        spotlightReindex: SpotlightReindexConfig = .init(),
        dockerStrain: DockerStrainConfig = .init(),
        memoryLeak: MemoryLeakConfig = .init(),
        idleMemoryHogs: IdleMemoryHogsConfig = .init()
    ) {
        self.formatVersion = formatVersion
        self.memoryPressure = memoryPressure
        self.swapThrashing = swapThrashing
        self.thermalThrottle = thermalThrottle
        self.overloadedSystem = overloadedSystem
        self.backupHogging = backupHogging
        self.highDiskIO = highDiskIO
        self.lowDiskSpace = lowDiskSpace
        self.runawayProcess = runawayProcess
        self.backupChokingForeground = backupChokingForeground
        self.memorySwapSpiral = memorySwapSpiral
        self.thermalThrottleAmplifier = thermalThrottleAmplifier
        self.diskMemoryContention = diskMemoryContention
        self.windowServerHog = windowServerHog
        self.spotlightReindex = spotlightReindex
        self.dockerStrain = dockerStrain
        self.memoryLeak = memoryLeak
        self.idleMemoryHogs = idleMemoryHogs
    }

    public static let `default` = RulesConfig()

    // Hand-rolled decode so every missing nested key falls back to the
    // default for that rule. Without this, a config file that only
    // tweaks one rule would have to enumerate every other rule too.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion)
            ?? Self.currentFormatVersion
        self.memoryPressure = try c.decodeIfPresent(MemoryPressureRuleConfig.self, forKey: .memoryPressure) ?? .init()
        self.swapThrashing = try c.decodeIfPresent(SwapThrashingRuleConfig.self, forKey: .swapThrashing) ?? .init()
        self.thermalThrottle = try c.decodeIfPresent(ThermalThrottleRuleConfig.self, forKey: .thermalThrottle) ?? .init()
        self.overloadedSystem = try c.decodeIfPresent(OverloadedSystemRuleConfig.self, forKey: .overloadedSystem) ?? .init()
        self.backupHogging = try c.decodeIfPresent(BackupHoggingRuleConfig.self, forKey: .backupHogging) ?? .init()
        self.highDiskIO = try c.decodeIfPresent(HighDiskIORuleConfig.self, forKey: .highDiskIO) ?? .init()
        self.lowDiskSpace = try c.decodeIfPresent(LowDiskSpaceRuleConfig.self, forKey: .lowDiskSpace) ?? .init()
        self.runawayProcess = try c.decodeIfPresent(RunawayProcessRuleConfig.self, forKey: .runawayProcess) ?? .init()
        self.backupChokingForeground = try c.decodeIfPresent(NarrativeToggle.self, forKey: .backupChokingForeground) ?? .init()
        self.memorySwapSpiral = try c.decodeIfPresent(NarrativeToggle.self, forKey: .memorySwapSpiral) ?? .init()
        self.thermalThrottleAmplifier = try c.decodeIfPresent(NarrativeToggle.self, forKey: .thermalThrottleAmplifier) ?? .init()
        self.diskMemoryContention = try c.decodeIfPresent(NarrativeToggle.self, forKey: .diskMemoryContention) ?? .init()
        self.windowServerHog = try c.decodeIfPresent(WindowServerHogConfig.self, forKey: .windowServerHog) ?? .init()
        self.spotlightReindex = try c.decodeIfPresent(SpotlightReindexConfig.self, forKey: .spotlightReindex) ?? .init()
        self.dockerStrain = try c.decodeIfPresent(DockerStrainConfig.self, forKey: .dockerStrain) ?? .init()
        self.memoryLeak = try c.decodeIfPresent(MemoryLeakConfig.self, forKey: .memoryLeak) ?? .init()
        self.idleMemoryHogs = try c.decodeIfPresent(IdleMemoryHogsConfig.self, forKey: .idleMemoryHogs) ?? .init()
    }
}

// MARK: - Standalone rule configs

public struct MemoryPressureRuleConfig: Codable, Sendable, Equatable {
    public let enabled: Bool
    public init(enabled: Bool = true) { self.enabled = enabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
    private enum CodingKeys: String, CodingKey { case enabled }
}

public struct SwapThrashingRuleConfig: Codable, Sendable, Equatable {
    public let enabled: Bool
    /// Swap-used threshold (in GB) for warning severity.
    public let warningGB: Double
    /// Promotes to critical at this much swap, *and* requires memory
    /// pressure to still be non-normal (see SwapThrashingRule's gate
    /// comment) *and* the page-in rate to exceed
    /// `thrashingPageInsPerSecond`.
    public let criticalGB: Double
    /// Page-in rate (pages/sec) above which we consider the machine to
    /// be *actively* thrashing swap, not just holding old pages on disk.
    /// 500/s at 16 KB pages ≈ 8 MB/s of paging traffic — enough to be
    /// felt on foreground input latency, low enough to catch real
    /// slowdowns without firing on the routine kernel housekeeping that
    /// happens after any wake-from-sleep event.
    public let thrashingPageInsPerSecond: Double
    public init(
        enabled: Bool = true,
        warningGB: Double = 2.0,
        criticalGB: Double = 6.0,
        thrashingPageInsPerSecond: Double = 500
    ) {
        self.enabled = enabled
        self.warningGB = warningGB
        self.criticalGB = criticalGB
        self.thrashingPageInsPerSecond = thrashingPageInsPerSecond
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.warningGB = try c.decodeIfPresent(Double.self, forKey: .warningGB) ?? 2.0
        self.criticalGB = try c.decodeIfPresent(Double.self, forKey: .criticalGB) ?? 6.0
        self.thrashingPageInsPerSecond = try c.decodeIfPresent(Double.self, forKey: .thrashingPageInsPerSecond) ?? 500
    }
    private enum CodingKeys: String, CodingKey {
        case enabled, warningGB, criticalGB, thrashingPageInsPerSecond
    }
}

public struct ThermalThrottleRuleConfig: Codable, Sendable, Equatable {
    public let enabled: Bool
    public init(enabled: Bool = true) { self.enabled = enabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
    private enum CodingKeys: String, CodingKey { case enabled }
}

public struct OverloadedSystemRuleConfig: Codable, Sendable, Equatable {
    public let enabled: Bool
    /// load_average / coreCount ratio that fires a warning.
    public let warningRatio: Double
    /// Ratio that promotes to critical.
    public let criticalRatio: Double
    public init(enabled: Bool = true, warningRatio: Double = 1.5, criticalRatio: Double = 3.0) {
        self.enabled = enabled
        self.warningRatio = warningRatio
        self.criticalRatio = criticalRatio
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.warningRatio = try c.decodeIfPresent(Double.self, forKey: .warningRatio) ?? 1.5
        self.criticalRatio = try c.decodeIfPresent(Double.self, forKey: .criticalRatio) ?? 3.0
    }
    private enum CodingKeys: String, CodingKey { case enabled, warningRatio, criticalRatio }
}

public struct BackupHoggingRuleConfig: Codable, Sendable, Equatable {
    public let enabled: Bool
    /// Single-process I/O rate (MB/s) above which a backup process is
    /// considered "active." Default 5 MB/s catches sustained scans
    /// without flagging idle housekeeping.
    public let activeIOMBs: Double
    /// CPU% above which a backup process counts as active even when I/O
    /// is quiet.
    public let activeCPUPercent: Double
    public init(enabled: Bool = true, activeIOMBs: Double = 5.0, activeCPUPercent: Double = 5.0) {
        self.enabled = enabled
        self.activeIOMBs = activeIOMBs
        self.activeCPUPercent = activeCPUPercent
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.activeIOMBs = try c.decodeIfPresent(Double.self, forKey: .activeIOMBs) ?? 5.0
        self.activeCPUPercent = try c.decodeIfPresent(Double.self, forKey: .activeCPUPercent) ?? 5.0
    }
    private enum CodingKeys: String, CodingKey { case enabled, activeIOMBs, activeCPUPercent }
}

public struct HighDiskIORuleConfig: Codable, Sendable, Equatable {
    public let enabled: Bool
    /// Modern Apple Silicon NVMe SSDs sustain 3–6 GB/s. The old 50 MB/s
    /// warning threshold (~1% utilization on such a drive) fired
    /// constantly on any active build/checkout and taught users to
    /// ignore the diagnosis. 200 MB/s is where sustained I/O actually
    /// starts to compete with the compressed-memory read path; 800 MB/s
    /// is genuine bandwidth pressure. Users on older / external
    /// spinning-disk setups can lower these via rules.json.
    public let warningMBs: Double
    public let criticalMBs: Double
    public init(enabled: Bool = true, warningMBs: Double = 200.0, criticalMBs: Double = 800.0) {
        self.enabled = enabled
        self.warningMBs = warningMBs
        self.criticalMBs = criticalMBs
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.warningMBs = try c.decodeIfPresent(Double.self, forKey: .warningMBs) ?? 200.0
        self.criticalMBs = try c.decodeIfPresent(Double.self, forKey: .criticalMBs) ?? 800.0
    }
    private enum CodingKeys: String, CodingKey { case enabled, warningMBs, criticalMBs }
}

public struct LowDiskSpaceRuleConfig: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let warningPercentUsed: Double
    public let criticalPercentUsed: Double
    public init(enabled: Bool = true, warningPercentUsed: Double = 85, criticalPercentUsed: Double = 95) {
        self.enabled = enabled
        self.warningPercentUsed = warningPercentUsed
        self.criticalPercentUsed = criticalPercentUsed
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.warningPercentUsed = try c.decodeIfPresent(Double.self, forKey: .warningPercentUsed) ?? 85
        self.criticalPercentUsed = try c.decodeIfPresent(Double.self, forKey: .criticalPercentUsed) ?? 95
    }
    private enum CodingKeys: String, CodingKey { case enabled, warningPercentUsed, criticalPercentUsed }
}

public struct RunawayProcessRuleConfig: Codable, Sendable, Equatable {
    public let enabled: Bool
    /// Sample count required before a process is called "sustained."
    public let minSustainedSamples: Int
    /// Beyond this many sustained samples, severity promotes to critical.
    public let extendedSustainedSamples: Int
    public init(enabled: Bool = true, minSustainedSamples: Int = 5, extendedSustainedSamples: Int = 20) {
        self.enabled = enabled
        self.minSustainedSamples = minSustainedSamples
        self.extendedSustainedSamples = extendedSustainedSamples
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.minSustainedSamples = try c.decodeIfPresent(Int.self, forKey: .minSustainedSamples) ?? 5
        self.extendedSustainedSamples = try c.decodeIfPresent(Int.self, forKey: .extendedSustainedSamples) ?? 20
    }
    private enum CodingKeys: String, CodingKey { case enabled, minSustainedSamples, extendedSustainedSamples }
}

// MARK: - Narrative configs

/// Narratives that have no tunable threshold beyond on/off.
public struct NarrativeToggle: Codable, Sendable, Equatable {
    public let enabled: Bool
    public init(enabled: Bool = true) { self.enabled = enabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
    private enum CodingKeys: String, CodingKey { case enabled }
}

public struct WindowServerHogConfig: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let cpuPercentThreshold: Double
    public init(enabled: Bool = true, cpuPercentThreshold: Double = 50) {
        self.enabled = enabled
        self.cpuPercentThreshold = cpuPercentThreshold
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.cpuPercentThreshold = try c.decodeIfPresent(Double.self, forKey: .cpuPercentThreshold) ?? 50
    }
    private enum CodingKeys: String, CodingKey { case enabled, cpuPercentThreshold }
}

public struct SpotlightReindexConfig: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let activeIOMBs: Double
    public init(enabled: Bool = true, activeIOMBs: Double = 20) {
        self.enabled = enabled
        self.activeIOMBs = activeIOMBs
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.activeIOMBs = try c.decodeIfPresent(Double.self, forKey: .activeIOMBs) ?? 20
    }
    private enum CodingKeys: String, CodingKey { case enabled, activeIOMBs }
}

public struct DockerStrainConfig: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let memoryWarnGB: Double
    public let memoryCritGB: Double
    public let cpuWarnPercent: Double
    public init(enabled: Bool = true, memoryWarnGB: Double = 4.0, memoryCritGB: Double = 8.0, cpuWarnPercent: Double = 50) {
        self.enabled = enabled
        self.memoryWarnGB = memoryWarnGB
        self.memoryCritGB = memoryCritGB
        self.cpuWarnPercent = cpuWarnPercent
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.memoryWarnGB = try c.decodeIfPresent(Double.self, forKey: .memoryWarnGB) ?? 4.0
        self.memoryCritGB = try c.decodeIfPresent(Double.self, forKey: .memoryCritGB) ?? 8.0
        self.cpuWarnPercent = try c.decodeIfPresent(Double.self, forKey: .cpuWarnPercent) ?? 50
    }
    private enum CodingKeys: String, CodingKey { case enabled, memoryWarnGB, memoryCritGB, cpuWarnPercent }
}

public struct MemoryLeakConfig: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let growthThresholdMB: Double
    public let memoryFloorMB: Double
    public let criticalGrowthThresholdMB: Double
    public init(enabled: Bool = true, growthThresholdMB: Double = 500, memoryFloorMB: Double = 1024, criticalGrowthThresholdMB: Double = 2048) {
        self.enabled = enabled
        self.growthThresholdMB = growthThresholdMB
        self.memoryFloorMB = memoryFloorMB
        self.criticalGrowthThresholdMB = criticalGrowthThresholdMB
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.growthThresholdMB = try c.decodeIfPresent(Double.self, forKey: .growthThresholdMB) ?? 500
        self.memoryFloorMB = try c.decodeIfPresent(Double.self, forKey: .memoryFloorMB) ?? 1024
        self.criticalGrowthThresholdMB = try c.decodeIfPresent(Double.self, forKey: .criticalGrowthThresholdMB) ?? 2048
    }
    private enum CodingKeys: String, CodingKey { case enabled, growthThresholdMB, memoryFloorMB, criticalGrowthThresholdMB }
}

public struct IdleMemoryHogsConfig: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let memoryFloorMB: Double
    public let minIdleSamples: Int
    public let combinedMemoryThresholdMB: Double
    public init(enabled: Bool = true, memoryFloorMB: Double = 500, minIdleSamples: Int = 100, combinedMemoryThresholdMB: Double = 2048) {
        self.enabled = enabled
        self.memoryFloorMB = memoryFloorMB
        self.minIdleSamples = minIdleSamples
        self.combinedMemoryThresholdMB = combinedMemoryThresholdMB
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.memoryFloorMB = try c.decodeIfPresent(Double.self, forKey: .memoryFloorMB) ?? 500
        self.minIdleSamples = try c.decodeIfPresent(Int.self, forKey: .minIdleSamples) ?? 100
        self.combinedMemoryThresholdMB = try c.decodeIfPresent(Double.self, forKey: .combinedMemoryThresholdMB) ?? 2048
    }
    private enum CodingKeys: String, CodingKey { case enabled, memoryFloorMB, minIdleSamples, combinedMemoryThresholdMB }
}

// MARK: - Top-level CodingKeys

private extension RulesConfig {
    enum CodingKeys: String, CodingKey {
        case formatVersion
        case memoryPressure, swapThrashing, thermalThrottle, overloadedSystem
        case backupHogging, highDiskIO, lowDiskSpace, runawayProcess
        case backupChokingForeground, memorySwapSpiral, thermalThrottleAmplifier
        case diskMemoryContention, windowServerHog, spotlightReindex
        case dockerStrain, memoryLeak, idleMemoryHogs
    }
}
