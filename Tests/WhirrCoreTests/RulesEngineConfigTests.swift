import XCTest
@testable import WhirrCore

/// Exercises the bits of the rules engine that change when callers
/// override the config — disabling rules, moving thresholds.
final class RulesEngineConfigTests: XCTestCase {
    private func snapshot(
        pressure: MemoryPressure = .normal,
        swap: UInt64 = 0,
        thermal: ThermalState = .nominal,
        load: LoadAverage = LoadAverage(oneMinute: 1, fiveMinute: 1, fifteenMinute: 1),
        diskFree: UInt64 = 500 * 1_073_741_824,
        diskTotal: UInt64 = 1000 * 1_073_741_824
    ) -> SystemSnapshot {
        SystemSnapshot(
            memoryUsedBytes: 8 * 1_073_741_824,
            memoryAvailableBytes: 8 * 1_073_741_824,
            memoryPressure: pressure,
            swapUsedBytes: swap,
            thermalState: thermal,
            loadAverage: load,
            rootDiskFreeBytes: diskFree,
            rootDiskTotalBytes: diskTotal
        )
    }

    // MARK: - Disabling

    func testDisablingSwapRuleSuppressesFiring() {
        let config = RulesConfig(swapThrashing: SwapThrashingRuleConfig(enabled: false))
        let engine = RulesEngine(config: config)
        let result = engine.evaluate(
            snapshot: snapshot(pressure: .warning, swap: 4 * 1_073_741_824),
            processes: []
        )
        XCTAssertFalse(result.contains { $0.title == "System is swapping heavily" })
    }

    func testDisablingMemoryRuleSuppressesFiring() {
        let config = RulesConfig(memoryPressure: MemoryPressureRuleConfig(enabled: false))
        let engine = RulesEngine(config: config)
        let result = engine.evaluate(snapshot: snapshot(pressure: .critical), processes: [])
        XCTAssertFalse(result.contains { $0.title == "Memory is saturated" })
    }

    func testDisablingNarrativeSuppressesFiring() {
        // Backup + memory warning would normally trigger BackupChokingForegroundNarrative.
        let config = RulesConfig(backupChokingForeground: NarrativeToggle(enabled: false))
        let engine = RulesEngine(config: config)
        let backup = ProcessSample(
            pid: 1, name: "bztransmit",
            cpuPercent: 10, memoryBytes: 0,
            diskReadBytesPerSec: 0, diskWriteBytesPerSec: 0
        )
        let result = engine.evaluate(
            snapshot: snapshot(pressure: .warning),
            processes: [backup]
        )
        XCTAssertFalse(result.contains { $0.kind == .narrative })
        // The standalone backup rule still fires — only the narrative was muted.
        XCTAssertTrue(result.contains { $0.title == "Backup is using your system" })
    }

    // MARK: - Threshold tuning

    func testSwapWarningGBLoweredFiresEarlier() {
        let config = RulesConfig(
            swapThrashing: SwapThrashingRuleConfig(enabled: true, warningGB: 1, criticalGB: 6)
        )
        let engine = RulesEngine(config: config)
        let result = engine.evaluate(
            snapshot: snapshot(pressure: .warning, swap: 1_500_000_000),
            processes: []
        )
        XCTAssertTrue(result.contains { $0.title == "System is swapping heavily" })
    }

    func testLowDiskSpaceWarningRaisedFiresLater() {
        // User raises warning to 95% — 90% no longer triggers.
        let config = RulesConfig(
            lowDiskSpace: LowDiskSpaceRuleConfig(
                enabled: true,
                warningPercentUsed: 95,
                criticalPercentUsed: 99
            )
        )
        let engine = RulesEngine(config: config)
        let result = engine.evaluate(
            snapshot: snapshot(diskFree: 100 * 1_073_741_824, diskTotal: 1000 * 1_073_741_824),
            processes: []
        )
        XCTAssertFalse(result.contains { $0.title == "Disk is nearly full" })
    }
}
