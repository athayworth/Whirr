import XCTest
@testable import WhirrCore

final class SnapshotPayloadTests: XCTestCase {
    func testRoundTripPreservesValues() throws {
        let original = SnapshotPayload(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            snapshot: SystemSnapshot(
                memoryUsedBytes: 16 * 1_073_741_824,
                memoryAvailableBytes: 4 * 1_073_741_824,
                memoryPressure: .critical,
                swapUsedBytes: 8 * 1_073_741_824,
                thermalState: .serious,
                loadAverage: LoadAverage(oneMinute: 12.3, fiveMinute: 9.8, fifteenMinute: 7.4)
            ),
            processes: [
                ProcessSample(
                    pid: 100, name: "ffmpeg",
                    cpuPercent: 312.5,
                    memoryBytes: 1_073_741_824,
                    diskReadBytesPerSec: 50_000_000,
                    diskWriteBytesPerSec: 1_000_000
                )
            ],
            diagnoses: [
                Diagnosis(
                    title: "Memory + swap death spiral",
                    detail: "RAM is full…",
                    severity: .critical,
                    culprits: ["ffmpeg"],
                    kind: .narrative
                )
            ]
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SnapshotPayload.self, from: encoded)

        XCTAssertEqual(decoded.formatVersion, SnapshotPayload.currentFormatVersion)
        XCTAssertEqual(decoded.snapshot.memoryUsedBytes, original.snapshot.memoryUsedBytes)
        XCTAssertEqual(decoded.snapshot.memoryPressure, .critical)
        XCTAssertEqual(decoded.snapshot.thermalState, .serious)
        XCTAssertEqual(decoded.snapshot.loadAverage.oneMinute, 12.3, accuracy: 0.001)
        XCTAssertEqual(decoded.processes.count, 1)
        XCTAssertEqual(decoded.processes[0].name, "ffmpeg")
        XCTAssertEqual(decoded.processes[0].diskIOBytesPerSec, 51_000_000)
        XCTAssertEqual(decoded.diagnoses.count, 1)
        XCTAssertEqual(decoded.diagnoses[0].kind, .narrative)
        XCTAssertEqual(decoded.diagnoses[0].title, "Memory + swap death spiral")
    }

    func testCurrentFormatVersionIsStable() {
        // If you intentionally bump the wire format, update this assertion
        // AND update the menu bar app's version check. The point of the
        // assertion is to make the bump visible in code review.
        XCTAssertEqual(SnapshotPayload.currentFormatVersion, 1)
    }
}

final class MemoryPressureResolutionTests: XCTestCase {
    func testKernelLevelIsAuthoritativeOverTheHandRolledEstimate() {
        // Real case: 0.6% of pages free (hand-roll says critical) while
        // the kernel reports level 2 (warning).
        XCTAssertEqual(SystemSampler.resolvePressure(kernelLevel: 2, dispatch: nil, handRolled: .critical), .warning)
        XCTAssertEqual(SystemSampler.resolvePressure(kernelLevel: 1, dispatch: .warning, handRolled: .critical), .normal)
        XCTAssertEqual(SystemSampler.resolvePressure(kernelLevel: 4, dispatch: nil, handRolled: .normal), .critical)
    }

    func testFallsBackToDispatchThenHandRolled() {
        XCTAssertEqual(SystemSampler.resolvePressure(kernelLevel: nil, dispatch: .warning, handRolled: .critical), .warning)
        XCTAssertEqual(SystemSampler.resolvePressure(kernelLevel: nil, dispatch: nil, handRolled: .warning), .warning)
        XCTAssertEqual(SystemSampler.resolvePressure(kernelLevel: 7, dispatch: nil, handRolled: .normal), .normal,
                       "an unrecognised level is ignored, not guessed")
    }

    func testLiveKernelLevelIsReadable() {
        XCTAssertNotNil(SystemSampler.kernelPressureLevel(), "kern.memorystatus_vm_pressure_level should be readable unprivileged")
    }
}

final class SwapInCounterTests: XCTestCase {
    func testActivelyPagingIsBuiltOnSwapInsNotFilePageIns() {
        // Opening an app pages in thousands of file pages; none of that
        // is swap. Only swap-ins mean macOS is reading swapped memory back.
        var vm = vm_statistics64_data_t()
        vm.pageins = 1_980_716_589
        vm.swapins = 213_738_824
        XCTAssertEqual(SystemSampler.swapInCounter(vm), 213_738_824)
    }
}
