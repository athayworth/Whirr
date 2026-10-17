import XCTest
@testable import WhirrCore

final class RulesEngineTests: XCTestCase {
    private let engine = RulesEngine()

    // MARK: - Helpers

    private func snapshot(
        used: UInt64 = 8 * .gb,
        available: UInt64 = 8 * .gb,
        pressure: MemoryPressure = .normal,
        swap: UInt64 = 0,
        thermal: ThermalState = .nominal,
        load: LoadAverage = LoadAverage(oneMinute: 1, fiveMinute: 1, fifteenMinute: 1),
        diskFree: UInt64 = 500 * .gb,
        diskTotal: UInt64 = 1000 * .gb,
        swapInsPerSec: Double = 0
    ) -> SystemSnapshot {
        SystemSnapshot(
            memoryUsedBytes: used,
            memoryAvailableBytes: available,
            memoryPressure: pressure,
            swapUsedBytes: swap,
            thermalState: thermal,
            loadAverage: load,
            rootDiskFreeBytes: diskFree,
            rootDiskTotalBytes: diskTotal,
            swapInsPerSecond: swapInsPerSec
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

    // MARK: - Idle memory hogs: frontmost-app exemption

    func testIdleHogsExemptsRecentlyFocusedApps() {
        // Arc has been CPU-idle for a long stretch, has a big memory
        // footprint, and would normally be flagged. But the user has
        // been focused on it — its bundle ID is in the recently-active
        // set. The narrative must skip it.
        let arc = process(
            pid: 100,
            name: "Arc",
            mem: 3 * .gb,
            idle: IdleMemoryHogsNarrative.minIdleSamples + 10
        )
        // A second hog nobody has focused, so we still have SOME
        // candidates and can verify Arc specifically got filtered
        // (not that the whole narrative was suppressed).
        let forgottenSlack = process(
            pid: 200,
            name: "Slack",
            mem: 3 * .gb,
            idle: IdleMemoryHogsNarrative.minIdleSamples + 10
        )
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [arc, forgottenSlack],
            // The rule reads bundle IDs via ctx.bundleIdentifier —
            // in tests we short-circuit by pattern-matching the raw
            // process name. Prod uses ProcessDescriptor's Info.plist
            // walk; the exemption logic is the same either way.
            bundleIdentifier: { proc in
                proc.name == "Arc" ? "company.arc.browser" : nil
            },
            recentlyActiveBundleIds: ["company.arc.browser"]
        )
        let unusedHogs = result.first { $0.title == "Big processes that look unused" }
        XCTAssertNotNil(unusedHogs, "Narrative should still fire for the unfocused Slack candidate")
        XCTAssertFalse(unusedHogs?.detail.contains("Arc") ?? false,
                       "Focused Arc must not appear in the unused-hogs card")
        XCTAssertTrue(unusedHogs?.detail.contains("Slack") ?? false,
                      "Unfocused Slack should still be flagged")
    }

    func testIdleHogsSuppressedEntirelyWhenAllCandidatesAreFocused() {
        // Every hog is a focused app — after exemption, no candidates
        // remain and the narrative doesn't fire.
        let arc = process(pid: 100, name: "Arc", mem: 3 * .gb,
                          idle: IdleMemoryHogsNarrative.minIdleSamples + 10)
        let xcode = process(pid: 101, name: "Xcode", mem: 4 * .gb,
                            idle: IdleMemoryHogsNarrative.minIdleSamples + 10)
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [arc, xcode],
            bundleIdentifier: { proc in
                switch proc.name {
                case "Arc": return "company.arc.browser"
                case "Xcode": return "com.apple.dt.Xcode"
                default: return nil
                }
            },
            recentlyActiveBundleIds: ["company.arc.browser", "com.apple.dt.Xcode"]
        )
        XCTAssertNil(result.first { $0.title == "Big processes that look unused" })
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

    // MARK: - SwapThrashingRule (split: active-paging vs volume-only)

    func testSwapBelowThresholdDoesNotFire() {
        let result = engine.evaluate(snapshot: snapshot(pressure: .warning, swap: 1 * .gb), processes: [])
        let swapTitles: Set<String> = ["System is actively paging", "Swap is holding old pages"]
        XCTAssertTrue(titles(result).allSatisfy { !swapTitles.contains($0) })
    }

    func testSwapVolumeOnlyEmitsSoftenedTitleAtWarning() {
        // 3 GB of swap, memory pressure elevated, but no page-in traffic
        // → we say "holding old pages" (warning) rather than the alarming
        // "actively paging" language. This is the case the user was
        // seeing perpetually before the split.
        let result = engine.evaluate(
            snapshot: snapshot(pressure: .warning, swap: 3 * .gb, swapInsPerSec: 0),
            processes: []
        )
        let swap = result.first { $0.title == "Swap is holding old pages" }
        XCTAssertEqual(swap?.severity, .warning)
        XCTAssertFalse(titles(result).contains("System is actively paging"))
    }

    func testActivePagingCriticalAt8GBWithHighPageInRate() {
        // 8 GB in swap + memory critical + real page-in traffic → the
        // full "actively paging" story, escalated to critical.
        let result = engine.evaluate(
            snapshot: snapshot(pressure: .critical, swap: 8 * .gb, swapInsPerSec: 2000),
            processes: []
        )
        let swap = result.first { $0.title == "System is actively paging" }
        XCTAssertEqual(swap?.severity, .critical)
    }

    func testActivePagingIsWarningBelowCriticalGB() {
        // Real thrashing but only 3 GB used — still warning, not critical.
        let result = engine.evaluate(
            snapshot: snapshot(pressure: .warning, swap: 3 * .gb, swapInsPerSec: 2000),
            processes: []
        )
        let swap = result.first { $0.title == "System is actively paging" }
        XCTAssertEqual(swap?.severity, .warning)
    }

    func testSwapStaysSilentWhenPressureNormal() {
        // The classic "heavy session ended, macOS still holds compressed
        // pages" case. Neither title fires — the machine is fine right now.
        let result = engine.evaluate(
            snapshot: snapshot(pressure: .normal, swap: 13 * .gb),
            processes: []
        )
        XCTAssertFalse(titles(result).contains("System is actively paging"))
        XCTAssertFalse(titles(result).contains("Swap is holding old pages"))
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
    //
    // Thresholds were raised (50/200 → 200/800 MB/s) to be honest about
    // modern NVMe SSDs. Below the new floor: no fire. In-between: warning.
    // Well past critical: critical.

    func testHighDiskIODoesNotFireBelowThreshold() {
        let proc = process(name: "Photos", readBps: 150 * .mb)
        let result = engine.evaluate(snapshot: snapshot(), processes: [proc])
        XCTAssertFalse(titles(result).contains("Disk is busy"))
    }

    func testHighDiskIOWarningFiresAt250MBps() {
        let proc = process(name: "Photos", readBps: 250 * .mb)
        let result = engine.evaluate(snapshot: snapshot(), processes: [proc])
        let diag = result.first { $0.title == "Disk is busy" }
        XCTAssertEqual(diag?.severity, .warning)
        XCTAssertTrue(diag?.detail.contains("reading") ?? false)
    }

    func testHighDiskIOAt900MBpsIsOnlyAWarningOnModernSSDs() {
        let proc = process(name: "ffmpeg", writeBps: 900 * .mb)
        let result = engine.evaluate(snapshot: snapshot(), processes: [proc])
        XCTAssertEqual(result.first { $0.title == "Disk is busy" }?.severity, .warning)
    }

    func testHighDiskIOCriticalFiresAt3GBps() {
        let proc = process(name: "ffmpeg", writeBps: 3000 * .mb)
        let result = engine.evaluate(snapshot: snapshot(), processes: [proc])
        let diag = result.first { $0.title == "Disk is busy" }
        XCTAssertEqual(diag?.severity, .critical)
        XCTAssertTrue(diag?.detail.contains("writing") ?? false)
    }

    func testHighDiskIOSkipsBackupProcesses() {
        // BackupHoggingRule owns these — HighDiskIORule shouldn't double-fire.
        let proc = process(name: "bztransmit", readBps: 400 * .mb)
        let result = engine.evaluate(snapshot: snapshot(), processes: [proc])
        XCTAssertFalse(titles(result).contains("Disk is busy"))
        XCTAssertTrue(titles(result).contains("Backup is using your system"))
    }

    func testHighDiskIOPicksHeaviestProcess() {
        let processes = [
            process(pid: 1, name: "lightweight", readBps: 250 * .mb),
            process(pid: 2, name: "heaviest", readBps: 600 * .mb),
            process(pid: 3, name: "middle", readBps: 400 * .mb)
        ]
        let result = engine.evaluate(snapshot: snapshot(), processes: processes)
        let diag = result.first { $0.title == "Disk is busy" }
        XCTAssertTrue(diag?.detail.contains("heaviest") ?? false)
        XCTAssertEqual(diag?.culprits.first, "heaviest")
    }

    // MARK: - LowDiskSpaceRule

    func testLowDiskSpaceWarnsUnderThirtyGBFree() {
        let result = engine.evaluate(
            snapshot: snapshot(diskFree: 25 * .gb, diskTotal: 1000 * .gb),
            processes: []
        )
        let disk = result.first { $0.title == "Disk is nearly full" }
        XCTAssertEqual(disk?.severity, .warning)
        XCTAssertTrue(disk?.detail.contains("25.0 GB") ?? false, disk?.detail ?? "")
    }

    func testLowDiskSpaceCriticalUnderTenGBFree() {
        let result = engine.evaluate(
            snapshot: snapshot(diskFree: 8 * .gb, diskTotal: 1000 * .gb),
            processes: []
        )
        XCTAssertEqual(result.first { $0.title == "Disk is nearly full" }?.severity, .critical)
    }

    func testAPercentageAloneIsNotLowDiskOnABigDrive() {
        // 95% of 2 TB still leaves 100 GB — plenty.
        let result = engine.evaluate(
            snapshot: snapshot(diskFree: 100 * .gb, diskTotal: 2000 * .gb),
            processes: []
        )
        XCTAssertNil(result.first { $0.title == "Disk is nearly full" })
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
        XCTAssertTrue(diag?.detail.contains("15 s") ?? false, diag?.detail ?? "")
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

    func testRunawayWhyShowsCommandLineWhenAvailable() {
        let proc = process(
            pid: 42, name: "node", cpu: 195,
            commandLine: "node /Users/me/projects/buggy-server.js",
            sustained: RunawayProcessRule.minSustainedSamples
        )
        let result = engine.evaluate(snapshot: snapshot(), processes: [proc])
        let diag = result.first { $0.title.contains("node") }
        XCTAssertTrue(diag?.evidence.contains { $0.contains("buggy-server.js") } ?? false,
                      "How Whirr knows should include the command line: \(diag?.evidence ?? [])")
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
        XCTAssertEqual(narrative?.title, "Backup is competing with your apps")
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
        // Needs *actively-paging* swap now (post-page-in-rate split), not
        // just volume — that's the whole point of the honesty fix. Add a
        // high page-in rate so the underlying swap rule emits the
        // active-paging title the spiral narrative depends on.
        let result = engine.evaluate(
            snapshot: snapshot(pressure: .critical, swap: 6 * .gb, swapInsPerSec: 1500),
            processes: [process(name: "Arc", mem: 8 * .gb)]
        )
        let narrative = result.first { $0.title == "Memory + swap death spiral" }
        XCTAssertNotNil(narrative)
        XCTAssertTrue(narrative?.detail.contains("Arc") ?? false,
                      "Expected top memory hog named in narrative")
    }

    func testMemorySwapSpiralDoesNotFireOnVolumeAloneAfterHeavySession() {
        // The core dishonesty fix: swap sitting at 6 GB with memory
        // pressure critical but no active paging should NOT be called
        // a "death spiral." No page-in traffic = no user-felt cost.
        let result = engine.evaluate(
            snapshot: snapshot(pressure: .critical, swap: 6 * .gb, swapInsPerSec: 0),
            processes: [process(name: "Arc", mem: 8 * .gb)]
        )
        XCTAssertFalse(titles(result).contains("Memory + swap death spiral"))
    }

    func testMemorySwapSpiralYieldsToBackupNarrative() {
        // When both narratives qualify, the more specific Backup story wins —
        // they shouldn't both fire and double up the message.
        let result = engine.evaluate(
            snapshot: snapshot(pressure: .critical, swap: 6 * .gb, swapInsPerSec: 1500),
            processes: [process(name: "bztransmit", cpu: 8)]
        )
        let narratives = result.filter { $0.kind == .narrative }
        XCTAssertEqual(narratives.count, 1)
        XCTAssertEqual(narratives.first?.title, "Backup is competing with your apps")
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
        let narrative = result.first { $0.title == "Heavy work while your Mac is hot" }
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
        XCTAssertNil(onlyThermal.first { $0.title == "Heavy work while your Mac is hot" })

        // Runaway alone — no narrative.
        let onlyRunaway = engine.evaluate(
            snapshot: snapshot(),
            processes: [process(name: "ffmpeg", cpu: 250,
                                sustained: RunawayProcessRule.minSustainedSamples)]
        )
        XCTAssertNil(onlyRunaway.first { $0.title == "Heavy work while your Mac is hot" })
    }

    func testDiskMemoryContentionNarrativeFires() {
        // Raise the disk I/O for this test above the new 200 MB/s floor.
        let result = engine.evaluate(
            snapshot: snapshot(pressure: .warning),
            processes: [process(name: "ffmpeg", readBps: 300 * .mb)]
        )
        let narrative = result.first { $0.title == "Heavy disk use while memory is tight" }
        XCTAssertNotNil(narrative)
        XCTAssertTrue(narrative?.detail.contains("ffmpeg") ?? false)
    }

    func testDiskMemoryContentionYieldsToMemorySwapSpiral() {
        // When both could fire, the more dire memory+swap story wins.
        // Add page-in traffic so the spiral qualifies under the new gate.
        let result = engine.evaluate(
            snapshot: snapshot(pressure: .critical, swap: 6 * .gb, swapInsPerSec: 1500),
            processes: [process(name: "ffmpeg", readBps: 300 * .mb, writeBps: 0)]
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
        XCTAssertEqual(narratives.first?.title, "Backup is competing with your apps")
    }

    // MARK: - WindowServerHogNarrative

    func testWindowServerNarrativeFiresAtHighCpu() {
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [process(name: "WindowServer", cpu: 75)]
        )
        let narrative = result.first { $0.title == "Graphics is working hard" }
        XCTAssertEqual(narrative?.severity, .warning)
    }

    func testWindowServerNarrativeNeverCritical() {
        // High WindowServer CPU is normal on high-refresh/5K displays, so
        // it's information, never a red alarm.
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [process(name: "WindowServer", cpu: 130)]
        )
        let narrative = result.first { $0.title == "Graphics is working hard" }
        XCTAssertEqual(narrative?.severity, .warning)
        XCTAssertTrue(narrative?.detail.contains("Common causes") ?? false)
    }

    func testWindowServerNarrativeDoesNotFireWhenIdle() {
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [process(name: "WindowServer", cpu: 20)]
        )
        XCTAssertNil(result.first { $0.title == "Graphics is working hard" })
    }

    // MARK: - SpotlightReindexNarrative

    func testSpotlightNarrativeFiresOnHighDiskIO() {
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [process(name: "mds_stores", cpu: 5, readBps: 60 * .mb)]
        )
        let narrative = result.first { $0.title == "Spotlight is indexing" }
        XCTAssertNotNil(narrative)
        XCTAssertTrue(narrative?.detail.contains("indexing") ?? false)
        XCTAssertFalse(narrative?.detail.contains("minutes") ?? true, "no invented duration")
    }

    func testSpotlightNarrativeFiresOnSustainedCpu() {
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [process(name: "mds_stores", cpu: 100,
                                sustained: RunawayProcessRule.minSustainedSamples)]
        )
        let narrative = result.first { $0.title == "Spotlight is indexing" }
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
        XCTAssertTrue(titles(result).contains("Spotlight is indexing"))
    }

    func testSpotlightDoesNotFireWhenIdle() {
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [process(name: "mds_stores", cpu: 1, readBps: 0)]
        )
        XCTAssertNil(result.first { $0.title == "Spotlight is indexing" })
    }

    // MARK: - Docker as a major share

    func testDockerHoldingAQuarterOfMemoryIsAMajorLoad() {
        // 16 GB Mac, Docker VM at 9 GB: Docker itself is the strain.
        let result = engine.evaluate(
            snapshot: snapshot(used: 14 * .gb, available: 2 * .gb),
            processes: [
                process(pid: 1, name: "com.docker.backend", mem: 1 * .gb),
                process(pid: 2, name: "com.apple.Virtualization.Virtua", mem: 8 * .gb)
            ]
        )
        let major = result.first { $0.title == DiagnosisTitles.dockerMajorLoad }
        XCTAssertNotNil(major)
        XCTAssertTrue(major?.detail.contains("56%") ?? false, major?.detail ?? "")
        XCTAssertNil(result.first { $0.title == DiagnosisTitles.dockerStrain })
    }

    func testDockerUsingMostOfTheCPUInUseIsAMajorLoad() {
        let result = engine.evaluate(
            snapshot: snapshot(used: 32 * .gb, available: 32 * .gb),
            processes: [
                process(pid: 1, name: "com.docker.backend", cpu: 20, mem: 1 * .gb),
                process(pid: 2, name: "com.apple.Virtualization.Virtua", cpu: 280, mem: 3 * .gb),
                process(pid: 3, name: "Safari", cpu: 40, mem: 1 * .gb)
            ]
        )
        XCTAssertNotNil(result.first { $0.title == DiagnosisTitles.dockerMajorLoad })
    }

    func testDockerCPUShareIsNotJudgedWithoutTheFullProcessList() {
        // Without the background helper, other users' processes are
        // invisible, so Docker's share of "all CPU" would be overstated.
        let result = engine.evaluate(
            snapshot: snapshot(used: 32 * .gb, available: 32 * .gb),
            processes: [
                process(pid: 1, name: "com.docker.backend", cpu: 20, mem: 1 * .gb),
                process(pid: 2, name: "com.apple.Virtualization.Virtua", cpu: 280, mem: 3 * .gb),
                process(pid: 3, name: "Safari", cpu: 40, mem: 1 * .gb)
            ],
            seesAllProcesses: false
        )
        XCTAssertNil(result.first { $0.title == DiagnosisTitles.dockerMajorLoad })
        XCTAssertNotNil(result.first { $0.title == DiagnosisTitles.dockerStrain })
    }

    // MARK: - DockerStrainNarrative

    func testDockerNarrativeFiresWhenDockerHeavy() {
        let result = engine.evaluate(
            snapshot: snapshot(used: 32 * .gb, available: 32 * .gb),
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
            snapshot: snapshot(used: 32 * .gb, available: 32 * .gb),
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

    func testMemoryGrowthIsNeverCalledALeakOrCritical() {
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [process(
                pid: 1, name: "node",
                mem: 6 * .gb,
                memDelta: Int64(3 * UInt64.gb)
            )]
        )
        let narrative = result.first { $0.title.contains("growing") }
        XCTAssertEqual(narrative?.severity, .warning)
        XCTAssertFalse(narrative?.detail.contains("leak") ?? true)
        XCTAssertTrue(narrative?.detail.contains("within the last 10 minutes") ?? false, narrative?.detail ?? "")
    }

    func testDurationsUseRealSampleTiming() {
        // 20 samples at 15 s each is 5 minutes, not 60 seconds.
        let result = engine.evaluate(
            snapshot: snapshot(),
            processes: [process(pid: 1, name: "node", cpu: 95, sustained: 20)],
            secondsPerSample: 15
        )
        let runaway = result.first { $0.title.hasSuffix("has been pegging CPU") }
        XCTAssertTrue(runaway?.detail.contains("5 min") ?? false, runaway?.detail ?? "")
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

    // MARK: - Explanations (how Whirr knows / why it matters)

    func testMacFindingsExplainFromTheirInputs() {
        let pressure = engine.evaluate(snapshot: snapshot(used: 14 * .gb, available: 2 * .gb, pressure: .critical), processes: [])
        EvidenceAccuracy.assertAllNumbers(pressure.first { $0.title == DiagnosisTitles.memorySaturated }, from: [14, 2])
        let over = engine.evaluate(snapshot: snapshot(load: LoadAverage(oneMinute: 52.8, fiveMinute: 50, fifteenMinute: 40)), processes: [])
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        EvidenceAccuracy.assertAllNumbers(over.first { $0.title == DiagnosisTitles.overloaded }, from: [52.8, cores, 52.8 / cores])
        let disk = engine.evaluate(snapshot: snapshot(diskFree: 25 * .gb, diskTotal: 1000 * .gb), processes: [])
        EvidenceAccuracy.assertAllNumbers(disk.first { $0.title == DiagnosisTitles.lowDisk }, from: [25, 1000, 97.5, 30, 10])
        let paging = engine.evaluate(snapshot: snapshot(pressure: .warning, swap: 3 * .gb, swapInsPerSec: 1500), processes: [])
        EvidenceAccuracy.assertAllNumbers(paging.first { $0.title == DiagnosisTitles.swapActivelyPaging }, from: [1500, 3])
        let hot = engine.evaluate(snapshot: snapshot(thermal: .serious), processes: [])
        XCTAssertFalse(hot.first { $0.title == DiagnosisTitles.thermalWarning }?.evidence.isEmpty ?? true)
        let busy = engine.evaluate(snapshot: snapshot(), processes: [process(name: "Photos", readBps: 250 * .mb)])
        EvidenceAccuracy.assertAllNumbers(busy.first { $0.title == DiagnosisTitles.diskBusy }, from: [250])
        let backup = engine.evaluate(snapshot: snapshot(), processes: [process(name: "bztransmit", cpu: 40, readBps: 12 * .mb)])
        EvidenceAccuracy.assertAllNumbers(backup.first { $0.title == DiagnosisTitles.backupUsing }, from: [12, 40])
        for d in pressure + over + disk + paging + hot + busy + backup where d.tier == .problem {
            XCTAssertNotNil(d.impact, d.title)
        }
    }

    func testRunawayDetailHasNoPathOrPidButEvidenceDoes() {
        let p = process(pid: 29168, name: "node", cpu: 198, commandLine: "/usr/local/bin/node server.js", sustained: 20)
        let r = engine.evaluate(snapshot: snapshot(), processes: [p]).first { $0.title.hasSuffix(DiagnosisTitles.runawaySuffix) }
        XCTAssertFalse(r?.detail.contains("29168") ?? true)
        XCTAssertFalse(r?.detail.contains("/usr/local") ?? true)
        XCTAssertTrue(r?.evidence.contains { $0.contains("29168") } ?? false)
        XCTAssertTrue(r?.detail.contains("1 min") ?? false, r?.detail ?? "")  // 20 × 3 s
    }
}

private extension UInt64 {
    static let kb: UInt64 = 1_024
    static let mb: UInt64 = 1_048_576
    static let gb: UInt64 = 1_073_741_824
}
