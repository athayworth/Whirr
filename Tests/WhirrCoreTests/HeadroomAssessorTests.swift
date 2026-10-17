import XCTest
@testable import WhirrCore

/// The headroom assessor drives the top-of-menu "can I keep working?"
/// line — the piece that answers the actual question a Harbr-era user
/// asks. These tests pin down the three-way verdict boundaries so we
/// don't quietly drift into "everything is comfortable / everything is
/// pressed" over time.
final class HeadroomAssessorTests: XCTestCase {
    private func snapshot(
        used: UInt64 = 8 * 1_073_741_824,
        available: UInt64 = 8 * 1_073_741_824,
        pressure: MemoryPressure = .normal,
        swapInsPerSec: Double = 0
    ) -> SystemSnapshot {
        SystemSnapshot(
            memoryUsedBytes: used,
            memoryAvailableBytes: available,
            memoryPressure: pressure,
            swapUsedBytes: 0,
            thermalState: .nominal,
            loadAverage: .zero,
            rootDiskFreeBytes: 500 * 1_073_741_824,
            rootDiskTotalBytes: 1000 * 1_073_741_824,
            swapInsPerSecond: swapInsPerSec
        )
    }

    private func process(name: String, mem: UInt64) -> ProcessSample {
        ProcessSample(pid: 1, name: name, cpuPercent: 0, memoryBytes: mem)
    }

    func testComfortableWithPlentyOfHeadroomAndNormalPressure() {
        let a = HeadroomAssessor.assess(
            snapshot: snapshot(available: 8 * 1_073_741_824),
            processes: []
        )
        XCTAssertEqual(a.verdict, .comfortable)
        XCTAssertTrue(a.headline.contains("Safe"),
                      "Comfortable headline should sound calm: \(a.headline)")
    }

    func testTightWhenPressureWarning() {
        // Kernel says "warning" pressure regardless of the byte count.
        let a = HeadroomAssessor.assess(
            snapshot: snapshot(available: 8 * 1_073_741_824, pressure: .warning),
            processes: []
        )
        XCTAssertEqual(a.verdict, .tight)
    }

    func testTightWhenAvailableBelowTightFloor() {
        // Available drops below ~3.5 GB but kernel hasn't escalated yet —
        // still call this "tight" so the user knows a heavy add would hurt.
        let a = HeadroomAssessor.assess(
            snapshot: snapshot(available: 3 * 1_073_741_824),
            processes: []
        )
        XCTAssertEqual(a.verdict, .tight)
    }

    func testPressedOnKernelCritical() {
        let a = HeadroomAssessor.assess(
            snapshot: snapshot(available: 5 * 1_073_741_824, pressure: .critical),
            processes: []
        )
        XCTAssertEqual(a.verdict, .pressed)
    }

    func testPressedOnHighSwapInRateUnderPressure() {
        // Reading swapped pages back while the kernel reports pressure is
        // real thrashing — pressed even before the kernel says critical.
        let a = HeadroomAssessor.assess(
            snapshot: snapshot(available: 5 * 1_073_741_824, pressure: .warning, swapInsPerSec: 2000),
            processes: []
        )
        XCTAssertEqual(a.verdict, .pressed)
        XCTAssertTrue(a.headline.contains("paging"))
    }

    func testSwapInsWithoutKernelPressureAreNotPressed() {
        // Brief swap-ins with plenty available and the kernel calm (e.g.
        // waking a long-idle app) aren't a memory problem.
        let a = HeadroomAssessor.assess(
            snapshot: snapshot(available: 5 * 1_073_741_824, pressure: .normal, swapInsPerSec: 2000),
            processes: []
        )
        XCTAssertNotEqual(a.verdict, .pressed)
    }

    func testTopHogNamed() {
        // Two candidates; the largest one should be surfaced by name.
        let a = HeadroomAssessor.assess(
            snapshot: snapshot(),
            processes: [
                process(name: "Arc", mem: 6 * 1_073_741_824),
                process(name: "Xcode", mem: 3 * 1_073_741_824)
            ]
        )
        XCTAssertEqual(a.topHogName, "Arc")
        XCTAssertTrue(a.context.contains("Arc"),
                      "Top-hog context should name the process: \(a.context)")
    }

    func testTinyProcessesNotNamedAsTopHog() {
        // A 300 MB process isn't a hog worth naming — the context should
        // fall back to the "no big hog" language.
        let a = HeadroomAssessor.assess(
            snapshot: snapshot(),
            processes: [process(name: "Finder", mem: 300 * 1_048_576)]
        )
        XCTAssertNil(a.topHogName)
        XCTAssertFalse(a.context.contains("Finder"),
                       "Small process shouldn't appear in headline context: \(a.context)")
    }

    func testHeadlineContainsAvailableGB() {
        // Guards against a refactor that would drop the numeric headroom
        // from the headline — the number is what makes this actionable.
        let a = HeadroomAssessor.assess(
            snapshot: snapshot(available: 6 * 1_073_741_824),
            processes: []
        )
        XCTAssertTrue(a.headline.contains("6.0 GB") || a.headline.contains("6 GB"),
                      "Headline should surface headroom in GB: \(a.headline)")
    }
}
