import XCTest
@testable import WhirrCore

/// The `subsumes` field lets a narrative tell the UI to hide the
/// lower-level standalone rows it explains (e.g., "Memory + swap death
/// spiral" hides "Memory is saturated"). If a subsumed title is misspelled,
/// or if a rule is renamed without updating the subsumers, the UI will
/// silently show duplicate rows again — no compile error.
///
/// These tests exercise the subsumption behaviorally: they build a
/// scenario where a narrative fires alongside its subsumed rules, then
/// assert the caller-visible list (as DiagnosesSection uses it) drops
/// the redundant rows. Anchoring on behavior rather than static strings
/// means adding a new subsumed title in one place stays covered without
/// having to update this file.
final class SubsumesValidationTests: XCTestCase {
    private func snapshot(
        pressure: MemoryPressure = .normal,
        swap: UInt64 = 0,
        swapInsPerSec: Double = 0,
        thermal: ThermalState = .nominal
    ) -> SystemSnapshot {
        SystemSnapshot(
            memoryUsedBytes: 8 * 1_073_741_824,
            memoryAvailableBytes: 8 * 1_073_741_824,
            memoryPressure: pressure,
            swapUsedBytes: swap,
            thermalState: thermal,
            loadAverage: .zero,
            rootDiskFreeBytes: 500 * 1_073_741_824,
            rootDiskTotalBytes: 1000 * 1_073_741_824,
            swapInsPerSecond: swapInsPerSec
        )
    }

    private func proc(
        name: String,
        cpu: Double = 0,
        mem: UInt64 = 0,
        readBps: UInt64 = 0
    ) -> ProcessSample {
        ProcessSample(
            pid: 1, name: name,
            cpuPercent: cpu, memoryBytes: mem,
            diskReadBytesPerSec: readBps, diskWriteBytesPerSec: 0
        )
    }

    /// Filter that mirrors DiagnosesSection's rendering rule: any
    /// standalone whose title appears in the union of visible
    /// narratives' `subsumes` lists is hidden.
    private func visibleAfterSubsumption(_ diagnoses: [Diagnosis]) -> [Diagnosis] {
        let subsumed = Set(
            diagnoses
                .filter { $0.kind == .narrative }
                .flatMap(\.subsumes)
        )
        return diagnoses.filter {
            $0.kind == .narrative || !subsumed.contains($0.title)
        }
    }

    // MARK: - MemorySwapSpiral

    func testMemorySwapSpiralHidesMemorySaturatedAndActivelyPaging() {
        let engine = RulesEngine()
        let raw = engine.evaluate(
            snapshot: snapshot(pressure: .critical, swap: 6 * 1_073_741_824, swapInsPerSec: 1500),
            processes: [proc(name: "Arc", mem: 8 * 1_073_741_824)]
        )
        // Sanity: the narrative and both standalones all fired.
        let titles = raw.map(\.title)
        XCTAssertTrue(titles.contains("Memory + swap death spiral"))
        XCTAssertTrue(titles.contains("Memory is saturated"))
        XCTAssertTrue(titles.contains("System is actively paging"))

        // After subsumption filter: the two standalones disappear,
        // narrative stays.
        let visible = visibleAfterSubsumption(raw).map(\.title)
        XCTAssertTrue(visible.contains("Memory + swap death spiral"))
        XCTAssertFalse(visible.contains("Memory is saturated"))
        XCTAssertFalse(visible.contains("System is actively paging"))
    }

    // MARK: - DiskMemoryContention

    func testDiskMemoryContentionHidesDiskBusyAndMemoryPressureRow() {
        let engine = RulesEngine()
        let raw = engine.evaluate(
            snapshot: snapshot(pressure: .warning),
            processes: [proc(name: "ffmpeg", readBps: 300 * 1_048_576)]
        )
        let titles = raw.map(\.title)
        XCTAssertTrue(titles.contains("Heavy disk use while memory is tight"))
        XCTAssertTrue(titles.contains("Disk is busy"))
        XCTAssertTrue(titles.contains("Memory is tight"))

        let visible = visibleAfterSubsumption(raw).map(\.title)
        XCTAssertTrue(visible.contains("Heavy disk use while memory is tight"))
        XCTAssertFalse(visible.contains("Disk is busy"))
        XCTAssertFalse(visible.contains("Memory is tight"))
    }

    // MARK: - BackupChoking

    func testBackupChokingHidesBackupAndSecondarySignals() {
        let engine = RulesEngine()
        let raw = engine.evaluate(
            snapshot: snapshot(pressure: .warning, thermal: .serious),
            processes: [proc(name: "bztransmit", cpu: 8)]
        )
        let titles = raw.map(\.title)
        XCTAssertTrue(titles.contains("Backup is competing with your apps"))
        XCTAssertTrue(titles.contains("Backup is using your system"))

        let visible = visibleAfterSubsumption(raw).map(\.title)
        XCTAssertTrue(visible.contains("Backup is competing with your apps"))
        // The narrative subsumes the backup + secondary signals it
        // references, so the standalone "Backup is using your system"
        // must drop out.
        XCTAssertFalse(visible.contains("Backup is using your system"))
    }

    // MARK: - Structural invariant

    func testSubsumedTitlesAreOnlyStandalones() {
        // A narrative subsuming another narrative would create a
        // rendering cycle. Verify all subsumed titles across the rule
        // set correspond to *standalone*-emitted titles by walking
        // every scenario we exercise elsewhere.
        let engine = RulesEngine()
        let scenarios: [[Diagnosis]] = [
            engine.evaluate(
                snapshot: snapshot(pressure: .critical, swap: 6 * 1_073_741_824, swapInsPerSec: 1500),
                processes: [proc(name: "Arc", mem: 8 * 1_073_741_824)]
            ),
            engine.evaluate(
                snapshot: snapshot(pressure: .warning),
                processes: [proc(name: "ffmpeg", readBps: 300 * 1_048_576)]
            ),
            engine.evaluate(
                snapshot: snapshot(pressure: .warning, thermal: .serious),
                processes: [proc(name: "bztransmit", cpu: 8)]
            )
        ]
        for diagnoses in scenarios {
            let narrativeTitles = Set(diagnoses.filter { $0.kind == .narrative }.map(\.title))
            let subsumed = Set(diagnoses.filter { $0.kind == .narrative }.flatMap(\.subsumes))
            // No narrative-emitted title should ever appear in any
            // narrative's subsumes list — that would risk cycles.
            let cycles = subsumed.intersection(narrativeTitles)
            XCTAssertTrue(cycles.isEmpty,
                          "Narrative-emitted title(s) subsumed by another narrative: \(cycles)")
        }
    }
}
