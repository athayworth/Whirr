import XCTest
@testable import WhirrCore

final class SnapshotPayloadTests: XCTestCase {
    func testRoundTripPreservesValues() throws {
        let original = SnapshotPayload(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            snapshot: SystemSnapshot(
                memoryUsedBytes: 16 * 1_073_741_824,
                memoryFreeBytes: 4 * 1_073_741_824,
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
