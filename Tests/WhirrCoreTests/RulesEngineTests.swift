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
        thermal: ProcessInfo.ThermalState = .nominal,
        load: (Double, Double, Double) = (1.0, 1.0, 1.0)
    ) -> SystemSnapshot {
        SystemSnapshot(
            memoryUsedBytes: used,
            memoryFreeBytes: free,
            memoryPressure: pressure,
            swapUsedBytes: swap,
            thermalState: thermal,
            loadAverage: load
        )
    }

    private func process(
        pid: Int32 = 1,
        name: String = "test",
        cpu: Double = 0,
        mem: UInt64 = 0,
        readBps: UInt64 = 0,
        writeBps: UInt64 = 0
    ) -> ProcessSample {
        ProcessSample(
            pid: pid,
            name: name,
            cpuPercent: cpu,
            memoryBytes: mem,
            diskReadBytesPerSec: readBps,
            diskWriteBytesPerSec: writeBps
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
        let result = engine.evaluate(snapshot: snapshot(load: (4.0, 4.0, 4.0)), processes: [])
        XCTAssertFalse(titles(result).contains("System is overloaded"))
    }

    func testHighLoadFires() {
        // Realistic stressed box: 1-minute load far above core count
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let result = engine.evaluate(
            snapshot: snapshot(load: (cores * 4.0, cores * 3.0, cores * 2.0)),
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

    // MARK: - RunawayProcessRule

    func testRunawayBelowThresholdDoesNotFire() {
        let proc = process(name: "node", cpu: 50)
        let result = engine.evaluate(snapshot: snapshot(), processes: [proc])
        XCTAssertFalse(titles(result).contains { $0.contains("using a lot of CPU") })
    }

    func testRunawayWarningFiresAt100Percent() {
        let proc = process(pid: 42, name: "node", cpu: 100)
        let result = engine.evaluate(snapshot: snapshot(), processes: [proc])
        let diag = result.first { $0.title.contains("node") }
        XCTAssertEqual(diag?.severity, .warning)
    }

    func testRunawayCriticalFiresAt250Percent() {
        let proc = process(pid: 42, name: "ffmpeg", cpu: 250)
        let result = engine.evaluate(snapshot: snapshot(), processes: [proc])
        let diag = result.first { $0.title.contains("ffmpeg") }
        XCTAssertEqual(diag?.severity, .critical)
    }

    // MARK: - Ordering

    func testDiagnosesSortedBySeverityDescending() {
        // Mix a critical, a warning, and an ok-severity diagnosis.
        // Processes are passed in CPU-descending order, matching the
        // contract that ProcessSampler.sample() provides to consumers.
        let processes = [
            process(pid: 2, name: "ffmpeg", cpu: 250),                     // runaway: .critical
            process(pid: 1, name: "bzfilelist", cpu: 10)                   // backup: .ok
        ]
        let result = engine.evaluate(
            snapshot: snapshot(pressure: .warning),                        // memory: .warning
            processes: processes
        )
        XCTAssertGreaterThanOrEqual(result.count, 3)
        for (a, b) in zip(result, result.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                a.severity, b.severity,
                "Diagnoses not sorted: \(a.title)(\(a.severity)) before \(b.title)(\(b.severity))"
            )
        }
    }
}

private extension UInt64 {
    static let kb: UInt64 = 1_024
    static let mb: UInt64 = 1_048_576
    static let gb: UInt64 = 1_073_741_824
}
