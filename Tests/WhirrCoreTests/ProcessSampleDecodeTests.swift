import XCTest
@testable import WhirrCore

/// Daemons installed from older builds write `ProcessSample` without
/// fields added later. Those payloads must still decode — otherwise the
/// app silently falls back to in-process sampling forever.
final class ProcessSampleDecodeTests: XCTestCase {
    func testDecodesPayloadMissingNewerFields() throws {
        let json = #"{"pid":1,"name":"bzserv","cpuPercent":3.5,"memoryBytes":100,"diskReadBytesPerSec":0,"diskWriteBytesPerSec":0,"commandLine":null,"sustainedHighCpuSamples":0}"#
        let p = try JSONDecoder().decode(ProcessSample.self, from: Data(json.utf8))
        XCTAssertEqual(p.name, "bzserv")
        XCTAssertEqual(p.sustainedIdleSamples, 0)
        XCTAssertNil(p.memoryDelta10MinBytes)
        XCTAssertNil(p.parentPid)
    }

    func testRoundTripsAllFields() throws {
        let original = ProcessSample(
            pid: 7, name: "x", cpuPercent: 1, memoryBytes: 2,
            diskReadBytesPerSec: 3, diskWriteBytesPerSec: 4, commandLine: "x -y",
            sustainedHighCpuSamples: 5, sustainedIdleSamples: 6,
            memoryDelta10MinBytes: -8, executablePath: "/bin/x", userId: 501, parentPid: 1
        )
        let decoded = try JSONDecoder().decode(ProcessSample.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }
}
