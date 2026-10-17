import XCTest
@testable import WhirrCore

/// Every diagnosis title that RulesEngine emits should either resolve
/// to a subtitle here (via static case or dynamic suffix) or be
/// deliberately opted-out. The dangerous failure mode is silent —
/// adding a new rule + shipping without a subtitle means macOS
/// notifications for that condition go out with just the title, no
/// action hint. These tests catch that at build time.
final class NotificationSubtitlesTests: XCTestCase {

    // MARK: - Static titles

    func testMemorySubtitles() {
        XCTAssertNotNil(NotificationSubtitles.subtitle(for: "Memory is saturated"))
        XCTAssertNotNil(NotificationSubtitles.subtitle(for: "Memory is tight"))
        XCTAssertNotNil(NotificationSubtitles.subtitle(for: "System is actively paging"))
        XCTAssertNotNil(NotificationSubtitles.subtitle(for: "Swap is holding old pages"))
        XCTAssertNotNil(NotificationSubtitles.subtitle(for: "Memory + swap death spiral"))
    }

    func testThermalSubtitles() {
        XCTAssertNotNil(NotificationSubtitles.subtitle(for: "CPU is critically hot"))
        XCTAssertNotNil(NotificationSubtitles.subtitle(for: "CPU is throttling from heat"))
        XCTAssertNotNil(NotificationSubtitles.subtitle(for: "Heavy work while your Mac is hot"))
    }

    func testDiskSubtitles() {
        XCTAssertNotNil(NotificationSubtitles.subtitle(for: "Disk is nearly full"))
        XCTAssertNotNil(NotificationSubtitles.subtitle(for: "Disk is busy"))
        XCTAssertNotNil(NotificationSubtitles.subtitle(for: "Heavy disk use while memory is tight"))
    }

    func testBackupSubtitles() {
        XCTAssertNotNil(NotificationSubtitles.subtitle(for: "Backup is using your system"))
        XCTAssertNotNil(NotificationSubtitles.subtitle(for: "Backup is competing with your apps"))
    }

    func testOtherNarrativeSubtitles() {
        XCTAssertNotNil(NotificationSubtitles.subtitle(for: "Graphics is working hard"))
        XCTAssertNotNil(NotificationSubtitles.subtitle(for: "Spotlight is indexing"))
        XCTAssertNotNil(NotificationSubtitles.subtitle(for: "Docker is using significant resources"))
        XCTAssertNotNil(NotificationSubtitles.subtitle(for: "Big processes that look unused"))
        XCTAssertNotNil(NotificationSubtitles.subtitle(for: "System is overloaded"))
    }

    // MARK: - Dynamic titles

    func testRunawayCpuSubtitleMatchesAnyProcessName() {
        // The rule emits "<friendly> has been pegging CPU". Subtitle
        // is matched by suffix so any process name works.
        XCTAssertNotNil(NotificationSubtitles.subtitle(for: "Node.js has been pegging CPU"))
        XCTAssertNotNil(NotificationSubtitles.subtitle(for: "Google Chrome has been pegging CPU"))
        XCTAssertNotNil(NotificationSubtitles.subtitle(for: "some-obscure-daemon has been pegging CPU"))
    }

    func testMemoryLeakSubtitleMatchesAnyProcessName() {
        XCTAssertNotNil(NotificationSubtitles.subtitle(for: "Arc memory has been growing"))
        XCTAssertNotNil(NotificationSubtitles.subtitle(for: "Slack memory has been growing"))
    }

    // MARK: - Coverage against RulesEngine

    /// If a new rule is added to RulesEngine without a subtitle here,
    /// this test surfaces it — we run every rule + narrative through
    /// scenarios that would fire them and assert coverage.
    ///
    /// The scenarios are picked to match the acceptance tests over in
    /// RulesEngineTests, so if any of those become out-of-date, the
    /// failure surfaces both here and there.
    func testEveryFireableDiagnosisHasASubtitle() {
        let engine = RulesEngine()
        let scenarios: [(name: String, snapshot: SystemSnapshot, processes: [ProcessSample])] = [
            (
                "critical memory + active paging + top hog",
                snapshot(pressure: .critical, swap: 6, swapInsPerSec: 1500),
                [proc(name: "Arc", mem: 8 * 1_073_741_824)]
            ),
            (
                "warning memory + disk-heavy process",
                snapshot(pressure: .warning),
                [proc(name: "ffmpeg", readBps: 300 * 1_048_576)]
            ),
            (
                "backup active + memory warning + thermal serious",
                snapshot(pressure: .warning, thermal: .serious),
                [proc(name: "bztransmit", cpu: 8)]
            ),
            (
                "runaway process + thermal critical",
                snapshot(thermal: .critical),
                [proc(name: "node", cpu: 250, sustainedHighCpuSamples: 5)]
            ),
            (
                "docker heavy",
                snapshot(),
                [
                    proc(name: "com.docker.backend", cpu: 40, mem: 5 * 1_073_741_824),
                    proc(name: "com.docker.vpnkit", cpu: 20, mem: 500 * 1_048_576)
                ]
            ),
            (
                "spotlight busy",
                snapshot(),
                [proc(name: "mds_stores", cpu: 80, readBps: 30 * 1_048_576, sustainedHighCpuSamples: 6)]
            ),
            (
                "windowserver hog",
                snapshot(),
                [proc(name: "WindowServer", cpu: 120)]
            ),
            (
                "memory leak + idle hogs",
                snapshot(),
                [
                    proc(name: "Slack", mem: 3 * 1_073_741_824, memoryDelta: 800 * 1_048_576),
                    proc(name: "Chrome", mem: 4 * 1_073_741_824, idleSamples: 200),
                    proc(name: "Xcode", mem: 3 * 1_073_741_824, idleSamples: 200)
                ]
            ),
            (
                "swap volume only, memory warning",
                snapshot(pressure: .warning, swap: 3),
                []
            ),
            (
                "disk nearly full",
                snapshot(diskFree: 20, diskTotal: 1000),
                []
            ),
            (
                "overloaded system",
                snapshot(load: LoadAverage(oneMinute: 60, fiveMinute: 60, fifteenMinute: 60)),
                []
            )
        ]

        var missing: [String] = []
        for (name, snap, processes) in scenarios {
            let diagnoses = engine.evaluate(snapshot: snap, processes: processes)
            for diag in diagnoses {
                if NotificationSubtitles.subtitle(for: diag.title) == nil {
                    missing.append("\(diag.title) [scenario: \(name)]")
                }
            }
        }
        XCTAssertTrue(missing.isEmpty,
                      "Diagnoses without notification subtitles — add cases in NotificationSubtitles.swift: \n\(missing.joined(separator: "\n"))")
    }

    // MARK: - Helpers

    private func snapshot(
        pressure: MemoryPressure = .normal,
        swap: UInt64 = 0,       // GB
        swapInsPerSec: Double = 0,
        thermal: ThermalState = .nominal,
        load: LoadAverage = LoadAverage(oneMinute: 1, fiveMinute: 1, fifteenMinute: 1),
        diskFree: UInt64 = 500, // GB
        diskTotal: UInt64 = 1000
    ) -> SystemSnapshot {
        SystemSnapshot(
            memoryUsedBytes: 8 * 1_073_741_824,
            memoryAvailableBytes: 8 * 1_073_741_824,
            memoryPressure: pressure,
            swapUsedBytes: swap * 1_073_741_824,
            thermalState: thermal,
            loadAverage: load,
            rootDiskFreeBytes: diskFree * 1_073_741_824,
            rootDiskTotalBytes: diskTotal * 1_073_741_824,
            swapInsPerSecond: swapInsPerSec
        )
    }

    private func proc(
        name: String,
        cpu: Double = 0,
        mem: UInt64 = 0,
        readBps: UInt64 = 0,
        sustainedHighCpuSamples: Int = 0,
        idleSamples: Int = 0,
        memoryDelta: Int64? = nil
    ) -> ProcessSample {
        ProcessSample(
            pid: 1, name: name,
            cpuPercent: cpu, memoryBytes: mem,
            diskReadBytesPerSec: readBps,
            diskWriteBytesPerSec: 0,
            sustainedHighCpuSamples: sustainedHighCpuSamples,
            sustainedIdleSamples: idleSamples,
            memoryDelta10MinBytes: memoryDelta
        )
    }
}
