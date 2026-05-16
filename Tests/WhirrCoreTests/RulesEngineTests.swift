import XCTest
@testable import WhirrCore

final class RulesEngineTests: XCTestCase {
    private let engine = RulesEngine()

    // MARK: - Helpers

    private func snapshot(
        used: UInt64 = 8 * .gb,
        free: UInt64 = 8 * .gb,
        pressure: MemoryPressure = .normal,
        swap: UInt64 = 0,
        thermal: ThermalState = .nominal,
        load: LoadAverage = LoadAverage(oneMinute: 1, fiveMinute: 1, fifteenMinute: 1),
        diskFree: UInt64 = 500 * .gb,
        diskTotal: UInt64 = 1000 * .gb
    ) -> SystemSnapshot {
        SystemSnapshot(
            memoryUsedBytes: used,
            memoryFreeBytes: free,
            memoryPressure: pressure,
            swapUsedBytes: swap,
            thermalState: thermal,
            loadAverage: load,
            rootDiskFreeBytes: diskFree,
            rootDiskTotalBytes: diskTotal
        )
    }

    private func process(
        pid: Int32 = 1,
        name: String = "test",
        cpu: Double = 0,
        mem: UInt64 = 0,
        readBps: UInt64 = 0,
        writeBps: UInt64 = 0,
        commandLine: String? = nil,
        sustained: Int = 0,
        idle: Int = 0,
        memDelta: Int64? = nil
    ) -> ProcessSample {
        ProcessSample(
            pid: pid,
            name: name,
            cpuPercent: cpu,
            memoryBytes: mem,
            diskReadBytesPerSec: readBps,
            diskWriteBytesPerSec: writeBps,
            commandLine: commandLine,
            sustainedHighCpuSamples: sustained,
            sustainedIdleSamples: idle,
            memoryDelta10MinBytes: memDelta
        )
    }

    private func titles(_ diagnoses: [Diagnosis]) -> [String] {
        diagnoses.map(\.title)
    }

    // MARK: - Idle baseline

    func testIdleSystemProducesNoDiagnoses() {
        let result = engine.evaluate(snapshot: snapshot(), processes: [])
        XCTAssertTrue(result.isEmpty, "Expected no diagnoses on an idle system, got: \(titles(result))")
    }

    // MARK: - MemoryPressureRule

    func testMemoryPressureCriticalFires() {
        let result = engine.evaluate(snapshot: snapshot(pressure: .critical), processes: [])
        XCTAssertEqual(result.first?.title, "Memory is saturated")
        XCTAssertEqual(result.first?.severity, .critical)
    }

    func testMemoryPressureWarningFires() {
        let result = engine.evaluate(snapshot: snapshot(pressure: .warning), processes: [])
        XCTAssertEqual(result.first?.title, "Memory is tight")
        XCTAssertEqual(result.first?.severity, .warning)
    }

    // MARK: - SwapThrashingRule

    func testSwapBelowThresholdDoesNotFire() {
        let result = engine.evaluate(snapshot: snapshot(swap: 1 * .gb), processes: [])
        XCTAssertFalse(titles(result).contains("System is swapping heavily"))
    }

    func testSwapWarningFiresAt3GB() {
        let result = engine.evaluate(snapshot: snapshot(swap: 3 * .gb), processes: [])
        let swap = result.first { $0.title == "System is swapping heavily" }
        XCTAssertEqual(swap?.severity, .warning)
    }

    func testSwapCriticalFiresAt8GB() {
        let result = engine.evaluate(snapshot: snapshot(swap: 8 * .gb), processes: [])
        let swap = result.first { $0.title == "System is swapping heavily" }
        XCTAssertEqual(swap?.severity, .critical)
    }

    // MARK: - ThermalThrottleRule

    func testThermalSeriousFiresAsWarning() {
        let result = engine.evaluate(snapshot: snapshot(thermal: .serious), processes: [])
        let throttle = result.first { $0.title == "CPU is throttling from heat" }
        XCTAssertEqual(throttle?.severity, .warning)
    }

    func testThermalCriticalFires() {
        let result = engine.evaluate(snapshot: snapshot(thermal: .critical), processes: [])
        let throttle = result.first { $0.title == "CPU is critically hot" }
        XCTAssertEqual(throttle?.severity, .critical)
    }

    // MARK: - OverloadedSystemRule

    func testLoadBelowRatioDoesNotFire() {
        // 4-core box at load 4.0 → ratio 1.0, under threshold
        let result = engine.evaluate(
            snapshot: snapshot(load: LoadAverage(oneMinute: 4, fiveMinute: 4, fifteenMinute: 4)),
            processes: []
        )
        XCTAssertFalse(titles(result).contains("System is overloaded"))
    }

    func testHighLoadFires() {
        // Realistic stressed box: 1-minute load far above core count
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let result = engine.evaluate(
            snapshot: snapshot(load: LoadAverage(oneMinute: cores * 4, fiveMinute: cores * 3, fifteenMinute: cores * 2)),
            processes: []
        )
        let overload = result.first { $0.title == "System is overloaded" }
        XCTAssertEqual(overload?.severity, .critical)
    }

    // MARK: - BackupHoggingRule

    func testBackupQuiescentDoesNotFire() {
        let backup = process(name: "bztransmit", cpu: 1.0, readBps: 1 * .mb)
        let result = engine.evaluate(snapshot: snapshot(), processes: [backup])
        XCTAssertFalse(titles(result).contains("Backup is using your system"))
    }

    func testBackupFiresOnHighIOEvenWithLowCPU() {
        // The whole point of the I/O-aware rewrite: a backup process reading
        // 50 MB/s is meaningful even at 2% CPU.
        let backup = process(name: "bztransmit", cpu: 2.0, readBps: 50 * .mb)
        let result = engine.evaluate(snapshot: snapshot(), processes: [backup])
        let diag = result.first { $0.title == "Backup is using your system" }
        XCTAssertNotNil(diag)
        XCTAssertEqual(diag?.severity, .warning)
        XCTAssertTrue(diag?.detail.contains("MB/s") ?? false,
                      "Expected detail to mention I/O rate, got: \(diag?.detail ?? "nil")")
    }

    func testBackupFiresOnHighCPU() {
        let backup = process(name: "backupd", cpu: 40.0)
        let result = engine.evaluate(snapshot: snapshot(), processes: [backup])
        let diag = result.first { $0.title == "Backup is using your system" }
        XCTAssertEqual(diag?.severity, .warning)
    }

    func testBackupCulpritsListedByName() {
        let processes = [
            process(pid: 1, name: "bztransmit", cpu: 10),
            process(pid: 2, name: "bzfilelist", cpu: 10)
        ]
        let result = engine.evaluate(snapshot: snapshot(), processes: processes)
        let diag = result.first { $0.title == "Backup is using your system" }
        XCTAssertEqual(Set(diag?.culprits ?? []), Set(["bztransmit", "bzfilelist"]))
    }

    // MARK: - HighDiskIORule

    func testHighDiskIODoesNotFireBelowThreshold() {
        let proc = process(name: "Photos", readBps: 40 * .mb)
        let result = engine.evaluate(snapshot: snapshot(), processes: [proc])
        XCTAssertFalse(titles(result).contains("Disk is busy"))
    }

    func testHighDiskIOWarningFiresAt60MBps() {
        let proc = process(name: "Photos", readBps: 60 * .mb)
        let result = engine.evaluate(snapshot: snapshot(), processes: [proc])
        let diag = result.first { $0.title == "Disk is busy" }
        XCTAssertEqual(diag?.severity, .warning)
        XCTAssertTrue(diag?.detail.contains("reading") ?? false)
    }

    func testHighDiskIOCriticalFiresAt250MBps() {
        let proc = process(name: "ffmpeg", writeBps: 250 * .mb)
        let result = engine.evaluate(snapshot: snapshot(), processes: [proc])
        let diag = result.first { $0.title == "Disk is busy" }
        XCTAssertEqual(diag?.severity, .critical)
        XCTAssertTrue(diag?.detail.contains("writing") ?? false)
    }

    func testHighDiskIOSkipsBackupProcesses() {
        // BackupHoggingRule owns these — HighDiskIORule shouldn't double-fire.
        let proc = process(name: "bztransmit", readBps: 200 * .mb)
        let result = engine.evaluate(snapshot: snapshot(), processes: [proc])
        XCTAssertFalse(titles(result).contains("Disk is busy"))
        XCTAssertTrue(titles(result).contains("Backup is using your system"))
    }

    func testHighDiskIOPicksHeaviestProcess() {
        let processes = [
            process(pid: 1, name: "lightweight", readBps: 60 * .mb),
            process(pid: 2, name: "heaviest", readBps: 300 * .mb),
            process(pid: 3, name: "middle", readBps: 100 * .mb)
        ]
        let result = engine.evaluate(snapshot: snapshot(), processes: processes)
        let diag = result.first { $0.title == "Disk is busy" }
        XCTAssertTrue(diag?.detail.contains("heaviest") ?? false)
        XCTAssertEqual(diag?.culprits.first, "heaviest")
    }

    // MARK: - LowDiskSpaceRule

    func testLowDiskSpaceFiresAt90PercentFull() {
        // 90% used = 100 GB free of 1000 GB total.
        let result = engine.evaluate(
            snapshot: snapshot(diskFree: 100 * .gb, diskTotal: 1000 * .gb),
            processes: []
        )
        let disk = result.first { $0.title == "Disk is nearly full" }
        XCTAssertEqual(disk?.severity, .warning)
        XCTAssertTrue(disk?.detail.contains("90%") ?? false)
    }

    func testLowDiskSpaceCriticalAt96PercentFull() {
        let result = engine.evaluate(
            snapshot: snapshot(diskFree: 40 * .gb, diskTotal: 1000 * .gb),
            processes: []
        )
        let disk = result.first { $0.title == "Disk is nearly full" }
        XCTAssertEqual(disk?.severity, .critical)
    }

    func testLowDiskSpaceDoesNotFireWhenPlentyFree() {
        let result = engine.evaluate(
            snapshot: snapshot(diskFree: 500 * .gb, diskTotal: 1000 * .gb),
            processes: []
        )
        XCTAssertNil(result.first { $0.title == "Disk is nearly full" })
    }

    // MARK: - RunawayProcessRule

    func testRunawayDoesNotFireOnBriefSpike() {
        // High CPU but no sustained history — brief spike, not a runaway.
        let proc = process(name: "node", cpu: 200, sustained: 1)
        let result = engine.evaluate(snapshot: snapshot(), processes: [proc])
        XCTAssertFalse(titles(result).contains { $0.contains("pegging CPU") })
    }

    func testRunawayFiresOnSustainedHighCpu() {
        let proc = process(pid: 42, name: "node", cpu: 100, sustained: RunawayProcessRule.minSustainedSamples)
        let result = engine.evaluate(snapshot: snapshot(), processes: [proc])
        let diag = result.first { $0.title.contains("node") }
        XCTAssertEqual(diag?.severity, .warning)
        XCTAssertTrue(diag?.detail.contains("seconds") ?? false)
    }

    func testRunawayCriticalWhenVeryHigh() {
        let proc = process(pid: 42, name: "ffmpeg", cpu: 250, sustained: RunawayProcessRule.minSustainedSamples)
        let result = engine.evaluate(snapshot: snapshot(), processes: [proc])
        let diag = result.first { $0.title.contains("ffmpeg") }
        XCTAssertEqual(diag?.severity, .critical)
    }

    func testRunawayCriticalWhenSustainedAtLength() {
        // Even moderate CPU becomes critical once it persists past the
        // extended-sustained window.
        let proc = process(pid: 42, name: "rsync", cpu: 95, sustained: RunawayProcessRule.extendedSustainedSamples)
        let result = engine.evaluate(snapshot: snapshot(), processes: [proc])
        let diag = result.first { $0.title.contains("rsync") }
        XCTAssertEqual(diag?.severity, .critical)
    }

    func testRunawayDetailShowsCommandLineWhenAvailable() {
        let proc = process(
            pid: 42, name: "node", cpu: 195,
            commandLine: "node /Users/me/projects/buggy-server.js",
            sustained: RunawayProcessRule.minSustainedSamples
        )
        let result = engine.evaluate(snapshot: snapshot(), processes: [proc])
        let diag = result.first { $0.title.contains("node") }
        XCTAssertTrue(diag?.detail.contains("buggy-server.js") ?? false,
                      "Detail should include command line: \(diag?.detail ?? "nil")")
    }

    func testRunawayDetailFallsBackToNameWhenNoCommandLine() {
        let proc = process(pid: 42, name: "kernel_task", cpu: 195, sustained: RunawayProcessRule.minSustainedSamples)
        let result = engine.evaluate(snapshot: snapshot(), processes: [proc])
        let diag = result.first { $0.title.contains("kernel_task") }
        XCTAssertNotNil(diag)
        // No assertion on detail beyond that it doesn't crash — name fallback path.
    }

    // MARK: - Ordering

    func testStandaloneDiagnosesSortedBySeverityDescending() {
        // Narratives lead, then standalone diagnoses are sorted by severity.
        // Pass processes CPU-desc to match ProcessSampler.sample()'s contract.
        let processes = [
            process(pid: 2, name: "ffmpeg", cpu: 250,                      // runaway: .critical
                    sustained: RunawayProcessRule.minSustainedSamples),
            process(pid: 1, name: "node", cpu: 10)                         // (no rule)
        ]
        let result = engine.evaluate(
            snapshot: snapshot(pressure: .warning),                        // memory: .warning
            processes: processes
        )
        let standalone = result.filter { $0.kind == .standalone }
        XCTAssertGreaterThanOrEqual(standalone.count, 2)
        for (a, b) in zip(standalone, standalone.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                a.severity, b.severity,
                "Standalone diagnoses not sorted: \(a.title)(\(a.severity)) before \(b.title)(\(b.severity))"
            )
        }
    }

    func testNarrativesAppearBeforeStandaloneDiagnoses() {
        // Backup + memory tight → BackupChokingForegroundNarrative fires.
        let result = engine.evaluate(
            snapshot: snapshot(pressure: .warning),
            processes: [process(name: "bztransmit", cpu: 8)]
        )
        let firstStandaloneIdx = result.firstIndex { $0.kind == .standalone }
        let lastNarrativeIdx = result.lastIndex { $0.kind == .narrative }
        XCTAssertNotNil(firstStandaloneIdx)
        XCTAssertNotNil(lastNarrativeIdx)
        if let f = firstStandaloneIdx, let l = lastNarrativeIdx {
            XCTAssertLessThan(l, f, "All narratives must precede all standalones")
        }
    }

    // MARK: - Narrative rules

    func testBackupChokingNarrativeFiresWhenBackupMeetsMemoryPressure() {
        let result = engine.evaluate(
            snapshot: snapshot(pressure: .warning),
            processes: [process(name: "bztransmit", cpu: 8)]
        )
        let narrative = result.first { $0.kind == .narrative }
        XCTAssertEqual(narrative?.title, "Foreground apps will feel frozen")
        XCTAssertTrue(narrative?.detail.contains("bztransmit") ?? false)
    }

    func testBackupChokingNarrativeDoesNotFireWithoutSecondarySignal() {
        // Backup alone without memory/swap/thermal — no narrative.
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [process(name: "bztransmit", cpu: 8)]
        )
        XCTAssertFalse(result.contains { $0.kind == .narrative })
    }

    func testMemorySwapSpiralNarrativeFires() {
        let result = engine.evaluate(
            snapshot: snapshot(pressure: .critical, swap: 6 * .gb),
            processes: [process(name: "Arc", mem: 8 * .gb)]
        )
        let narrative = result.first { $0.title == "Memory + swap death spiral" }
        XCTAssertNotNil(narrative)
        XCTAssertTrue(narrative?.detail.contains("Arc") ?? false,
                      "Expected top memory hog named in narrative")
    }

    func testMemorySwapSpiralYieldsToBackupNarrative() {
        // When both narratives qualify, the more specific Backup story wins —
        // they shouldn't both fire and double up the message.
        let result = engine.evaluate(
            snapshot: snapshot(pressure: .critical, swap: 6 * .gb),
            processes: [process(name: "bztransmit", cpu: 8)]
        )
        let narratives = result.filter { $0.kind == .narrative }
        XCTAssertEqual(narratives.count, 1)
        XCTAssertEqual(narratives.first?.title, "Foreground apps will feel frozen")
    }

    func testBackupNarrativeDescribesActualSecondarySignal() {
        // Backup + thermal-only (no memory pressure). Detail must NOT claim
        // memory is involved when it isn't.
        let result = engine.evaluate(
            snapshot: snapshot(thermal: .serious),
            processes: [process(name: "bztransmit", cpu: 8)]
        )
        let narrative = result.first { $0.kind == .narrative }
        XCTAssertNotNil(narrative)
        XCTAssertTrue(narrative?.detail.contains("throttling") ?? false,
                      "Detail should mention thermal: \(narrative?.detail ?? "nil")")
        XCTAssertFalse(narrative?.detail.contains("memory is tight") ?? true,
                       "Detail should NOT claim memory is tight when only thermal fired")
        XCTAssertFalse(narrative?.detail.contains("swapping") ?? true,
                       "Detail should NOT claim swapping when only thermal fired")
    }

    func testThermalAmplifierNarrativeFires() {
        let result = engine.evaluate(
            snapshot: snapshot(thermal: .critical),
            processes: [process(pid: 42, name: "ffmpeg", cpu: 250,
                                sustained: RunawayProcessRule.minSustainedSamples)]
        )
        let narrative = result.first { $0.title == "Cooling matters more than killing right now" }
        XCTAssertNotNil(narrative)
        XCTAssertTrue(narrative?.detail.contains("ffmpeg") ?? false)
        XCTAssertEqual(narrative?.severity, .critical)
    }

    func testThermalAmplifierNeedsBothSignals() {
        // Thermal alone — no narrative.
        let onlyThermal = engine.evaluate(
            snapshot: snapshot(thermal: .serious),
            processes: []
        )
        XCTAssertNil(onlyThermal.first { $0.title == "Cooling matters more than killing right now" })

        // Runaway alone — no narrative.
        let onlyRunaway = engine.evaluate(
            snapshot: snapshot(),
            processes: [process(name: "ffmpeg", cpu: 250,
                                sustained: RunawayProcessRule.minSustainedSamples)]
        )
        XCTAssertNil(onlyRunaway.first { $0.title == "Cooling matters more than killing right now" })
    }

    func testDiskMemoryContentionNarrativeFires() {
        let result = engine.evaluate(
            snapshot: snapshot(pressure: .warning),
            processes: [process(name: "ffmpeg", readBps: 80 * .mb)]
        )
        let narrative = result.first { $0.title == "Disk and memory are fighting for the same SSD" }
        XCTAssertNotNil(narrative)
        XCTAssertTrue(narrative?.detail.contains("ffmpeg") ?? false)
    }

    func testDiskMemoryContentionYieldsToMemorySwapSpiral() {
        // When both could fire, the more dire memory+swap story wins.
        let result = engine.evaluate(
            snapshot: snapshot(pressure: .critical, swap: 6 * .gb),
            processes: [process(name: "ffmpeg", readBps: 80 * .mb, writeBps: 0)]
        )
        let narratives = result.filter { $0.kind == .narrative }
        XCTAssertEqual(narratives.count, 1)
        XCTAssertEqual(narratives.first?.title, "Memory + swap death spiral")
    }

    func testDiskMemoryContentionYieldsToBackup() {
        // Backup narrative takes precedence over the generic disk+memory story.
        let result = engine.evaluate(
            snapshot: snapshot(pressure: .warning),
            processes: [
                process(pid: 1, name: "bztransmit", readBps: 20 * .mb),
                process(pid: 2, name: "ffmpeg", readBps: 80 * .mb)
            ]
        )
        let narratives = result.filter { $0.kind == .narrative }
        XCTAssertEqual(narratives.count, 1)
        XCTAssertEqual(narratives.first?.title, "Foreground apps will feel frozen")
    }

    // MARK: - WindowServerHogNarrative

    func testWindowServerNarrativeFiresAtHighCpu() {
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [process(name: "WindowServer", cpu: 75)]
        )
        let narrative = result.first { $0.title == "Graphics layer is bottlenecking" }
        XCTAssertEqual(narrative?.severity, .warning)
    }

    func testWindowServerNarrativeCriticalAt100Percent() {
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [process(name: "WindowServer", cpu: 130)]
        )
        let narrative = result.first { $0.title == "Graphics layer is bottlenecking" }
        XCTAssertEqual(narrative?.severity, .critical)
    }

    func testWindowServerNarrativeDoesNotFireWhenIdle() {
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [process(name: "WindowServer", cpu: 20)]
        )
        XCTAssertNil(result.first { $0.title == "Graphics layer is bottlenecking" })
    }

    // MARK: - SpotlightReindexNarrative

    func testSpotlightNarrativeFiresOnHighDiskIO() {
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [process(name: "mds_stores", cpu: 5, readBps: 60 * .mb)]
        )
        let narrative = result.first { $0.title == "Spotlight is reindexing" }
        XCTAssertNotNil(narrative)
        XCTAssertTrue(narrative?.detail.contains("rebuilding") ?? false)
    }

    func testSpotlightNarrativeFiresOnSustainedCpu() {
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [process(name: "mds_stores", cpu: 100,
                                sustained: RunawayProcessRule.minSustainedSamples)]
        )
        let narrative = result.first { $0.title == "Spotlight is reindexing" }
        XCTAssertNotNil(narrative)
    }

    func testSpotlightSuppressesGenericDiskBusyDiagnosis() {
        // HighDiskIORule should NOT fire for mds_stores — Spotlight narrative
        // owns that story with better framing.
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [process(name: "mds_stores", cpu: 5, readBps: 100 * .mb)]
        )
        XCTAssertFalse(titles(result).contains("Disk is busy"))
        XCTAssertTrue(titles(result).contains("Spotlight is reindexing"))
    }

    func testSpotlightDoesNotFireWhenIdle() {
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [process(name: "mds_stores", cpu: 1, readBps: 0)]
        )
        XCTAssertNil(result.first { $0.title == "Spotlight is reindexing" })
    }

    // MARK: - DockerStrainNarrative

    func testDockerNarrativeFiresWhenDockerHeavy() {
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [
                process(pid: 1, name: "com.docker.backend", mem: 1 * .gb),
                process(pid: 2, name: "com.apple.Virtualization.Virtua", mem: 7 * .gb)
            ]
        )
        let narrative = result.first { $0.title == "Docker is using significant resources" }
        XCTAssertNotNil(narrative)
        XCTAssertTrue(narrative?.detail.contains("docker stats") ?? false,
                      "Detail should suggest `docker stats`")
    }

    func testDockerNarrativeCriticalAt8GB() {
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [
                process(pid: 1, name: "com.docker.backend", mem: 2 * .gb),
                process(pid: 2, name: "com.apple.Virtualization.Virtua", mem: 8 * .gb)
            ]
        )
        let narrative = result.first { $0.title == "Docker is using significant resources" }
        XCTAssertEqual(narrative?.severity, .critical)
    }

    func testDockerNarrativeStaysQuietWhenDockerIdle() {
        // Docker Desktop running but not doing much — don't pester.
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [
                process(pid: 1, name: "com.docker.backend", mem: 800 * .mb),
                process(pid: 2, name: "com.apple.Virtualization.Virtua", mem: 1 * .gb)
            ]
        )
        XCTAssertNil(result.first { $0.title == "Docker is using significant resources" })
    }

    func testDockerNarrativeRequiresDockerBackendPresent() {
        // Virtualization framework alone (Parallels, UTM, or some other VM
        // user) — we don't attribute that to Docker.
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [
                process(pid: 1, name: "com.apple.Virtualization.Virtua", mem: 8 * .gb)
            ]
        )
        XCTAssertNil(result.first { $0.title == "Docker is using significant resources" })
    }

    // MARK: - IdleMemoryHogsNarrative

    func testIdleMemoryHogsFires() {
        // Two idle 2 GB processes — combined 4 GB, above the 2 GB threshold.
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [
                process(pid: 1, name: "node",
                        mem: 2 * .gb,
                        idle: IdleMemoryHogsNarrative.minIdleSamples + 50),
                process(pid: 2, name: "java",
                        mem: 2 * .gb,
                        idle: IdleMemoryHogsNarrative.minIdleSamples + 20)
            ]
        )
        let narrative = result.first { $0.title == "Big processes that look unused" }
        XCTAssertNotNil(narrative)
        XCTAssertEqual(narrative?.severity, .ok)  // Informational, not alarming
        XCTAssertTrue(narrative?.detail.contains("node") ?? false)
        XCTAssertTrue(narrative?.detail.contains("java") ?? false)
    }

    func testIdleMemoryHogsStaysQuietBelowCombinedThreshold() {
        // A single big idle process is below the 2 GB combined threshold.
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [
                process(pid: 1, name: "node",
                        mem: 1 * .gb,
                        idle: IdleMemoryHogsNarrative.minIdleSamples + 50)
            ]
        )
        XCTAssertNil(result.first { $0.title == "Big processes that look unused" })
    }

    func testIdleMemoryHogsIgnoresSmallProcesses() {
        // Even if a 200 MB process has been idle forever, it's not worth flagging.
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [
                process(pid: 1, name: "small-server",
                        mem: 200 * .mb,
                        idle: 10_000)
            ]
        )
        XCTAssertNil(result.first { $0.title == "Big processes that look unused" })
    }

    // MARK: - MemoryLeakNarrative

    func testMemoryLeakFiresOnSignificantGrowth() {
        // A 5 GB process that grew by 1.5 GB over 10 minutes.
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [process(
                pid: 1, name: "bzserv",
                mem: 5 * .gb + 500 * .mb,
                memDelta: Int64(1.5 * Double(UInt64.gb))
            )]
        )
        let narrative = result.first { $0.title.contains("bzserv") && $0.title.contains("growing") }
        XCTAssertNotNil(narrative)
        XCTAssertEqual(narrative?.severity, .warning)
        XCTAssertTrue(narrative?.detail.contains("10 minutes") ?? false)
    }

    func testMemoryLeakCriticalAtTwoGigGrowth() {
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [process(
                pid: 1, name: "node",
                mem: 6 * .gb,
                memDelta: Int64(3 * UInt64.gb)
            )]
        )
        let narrative = result.first { $0.title.contains("growing") }
        XCTAssertEqual(narrative?.severity, .critical)
    }

    func testMemoryLeakIgnoresProcessesBelowFloor() {
        // 600 MB process growing 500 MB — below the 1 GB current-size floor.
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [process(
                pid: 1, name: "small",
                mem: 600 * .mb,
                memDelta: Int64(500 * UInt64.mb)
            )]
        )
        XCTAssertNil(result.first { $0.title.contains("growing") })
    }

    func testMemoryLeakIgnoresShrinkingProcesses() {
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [process(
                pid: 1, name: "bzserv",
                mem: 3 * .gb,
                memDelta: -Int64(2 * UInt64.gb)  // Lost 2 GB — good news, not a leak
            )]
        )
        XCTAssertNil(result.first { $0.title.contains("growing") })
    }

    func testMemoryLeakRequiresHistory() {
        // memDelta nil = sampler doesn't have enough history yet (process
        // only just became visible, or sampler just started).
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [process(
                pid: 1, name: "node",
                mem: 5 * .gb,
                memDelta: nil
            )]
        )
        XCTAssertNil(result.first { $0.title.contains("growing") })
    }

    func testIdleMemoryHogsRequiresSustainedIdleness() {
        // A 4 GB process that's only been idle for 1 minute isn't a candidate —
        // could just be between operations.
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [
                process(pid: 1, name: "node",
                        mem: 4 * .gb,
                        idle: 5)  // Way below minIdleSamples
            ]
        )
        XCTAssertNil(result.first { $0.title == "Big processes that look unused" })
    }
}

private extension UInt64 {
    static let kb: UInt64 = 1_024
    static let mb: UInt64 = 1_048_576
    static let gb: UInt64 = 1_073_741_824
}
