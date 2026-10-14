import XCTest
@testable import WhirrCore

final class SamplingPipelineTests: XCTestCase {
    private var tmpDir: URL!
    private var snapshotPath: String!
    private var historyPath: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhirrPipelineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        snapshotPath = tmpDir.appendingPathComponent("snapshot.json").path
        historyPath  = tmpDir.appendingPathComponent("history.json").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makePipeline(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> SamplingPipeline {
        SamplingPipeline(
            snapshotPath: snapshotPath,
            historyPath: historyPath,
            freshnessWindow: 10,
            clock: { now }
        )
    }

    private func writeSnapshot(
        capturedAt: Date,
        formatVersion: Int = SnapshotPayload.currentFormatVersion,
        memoryPressure: MemoryPressure = .critical
    ) throws {
        // We write JSON by hand so we can override `formatVersion` (which the
        // public initializer pins) and test the version-mismatch path.
        let dict: [String: Any] = [
            "formatVersion": formatVersion,
            "capturedAt": ISO8601DateFormatter().string(from: capturedAt),
            "snapshot": [
                "memoryUsedBytes": 16 * 1_073_741_824,
                "memoryFreeBytes": 4 * 1_073_741_824,
                "memoryPressure": memoryPressure.rawValue,
                "swapUsedBytes": 8 * 1_073_741_824,
                "thermalState": ThermalState.serious.rawValue,
                "loadAverage": [
                    "oneMinute": 8.0, "fiveMinute": 6.0, "fifteenMinute": 4.0
                ],
                "rootDiskFreeBytes": 100 * 1_073_741_824,
                "rootDiskTotalBytes": 1000 * 1_073_741_824
            ],
            "processes": [],
            "diagnoses": []
        ]
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: snapshotPath))
    }

    private func writeRaw(_ contents: String) throws {
        try contents.data(using: .utf8)!.write(to: URL(fileURLWithPath: snapshotPath))
    }

    // MARK: - Tests

    func testMissingFileFallsBackToInProcess() async {
        // No file written. The pipeline should still produce a result (the
        // in-process sampler runs end-to-end on the host) and label its
        // source as .inProcess.
        let pipeline = makePipeline()
        let result = await pipeline.tick()
        XCTAssertEqual(result.source, .inProcess)
        XCTAssertTrue(result.history.isEmpty, "in-process path doesn't carry history")
    }

    func testFreshDaemonFileIsUsed() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeSnapshot(capturedAt: now.addingTimeInterval(-2))  // 2s old
        let pipeline = makePipeline(now: now)
        let result = await pipeline.tick()
        XCTAssertEqual(result.source, .daemon)
        XCTAssertEqual(result.snapshot.memoryUsedBytes, 16 * 1_073_741_824)
    }

    func testStaleDaemonFileFallsBackToInProcess() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // 60s old — well past the 10s freshness window. The pipeline should
        // treat the daemon as gone and sample in-process instead.
        try writeSnapshot(capturedAt: now.addingTimeInterval(-60))
        let pipeline = makePipeline(now: now)
        let result = await pipeline.tick()
        XCTAssertEqual(result.source, .inProcess)
    }

    func testFormatVersionMismatchFallsBackToInProcess() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeSnapshot(
            capturedAt: now,
            formatVersion: SnapshotPayload.currentFormatVersion + 99
        )
        let pipeline = makePipeline(now: now)
        let result = await pipeline.tick()
        XCTAssertEqual(
            result.source, .inProcess,
            "Unknown wire format must fall back rather than guess at the payload"
        )
    }

    func testCorruptJSONFallsBackToInProcess() async throws {
        try writeRaw("{not even valid json")
        let pipeline = makePipeline()
        let result = await pipeline.tick()
        XCTAssertEqual(result.source, .inProcess)
    }

    func testEmptyFileFallsBackToInProcess() async throws {
        try writeRaw("")
        let pipeline = makePipeline()
        let result = await pipeline.tick()
        XCTAssertEqual(result.source, .inProcess)
    }

    func testRulesEngineRunsAgainstDaemonPayload() async throws {
        // The daemon's snapshot has critical memory pressure + 8 GB swap.
        // Even though the wire payload's `diagnoses` array is empty, the
        // pipeline must re-run the rules engine on the host (the daemon
        // binary may be older than the app) and produce diagnoses.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeSnapshot(capturedAt: now, memoryPressure: .critical)
        let pipeline = makePipeline(now: now)
        let result = await pipeline.tick()
        XCTAssertEqual(result.source, .daemon)
        XCTAssertFalse(
            result.diagnoses.isEmpty,
            "Memory pressure + heavy swap should trigger rules even when wire diagnoses is empty"
        )
        XCTAssertTrue(result.diagnoses.contains { $0.title == "Memory is saturated" })
    }
}

// MARK: - Daemon status

extension SamplingPipelineTests {
    func testDaemonStatusAbsentWhenNoFile() async {
        let result = await makePipeline().tick()
        XCTAssertEqual(result.daemonStatus, .absent)
        XCTAssertEqual(result.source, .inProcess)
    }

    func testDaemonStatusUndecodableForGarbage() async throws {
        try Data("not json".utf8).write(to: URL(fileURLWithPath: snapshotPath))
        let result = await makePipeline().tick()
        XCTAssertEqual(result.daemonStatus, .undecodable)
        XCTAssertEqual(result.source, .inProcess)
    }

    func testDaemonStatusStaleForOldSnapshot() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeSnapshot(capturedAt: now.addingTimeInterval(-60))
        let result = await makePipeline(now: now).tick()
        XCTAssertEqual(result.daemonStatus, .stale)
    }

    func testDaemonStatusFreshForCurrentSnapshot() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeSnapshot(capturedAt: now.addingTimeInterval(-2))
        let result = await makePipeline(now: now).tick()
        XCTAssertEqual(result.daemonStatus, .fresh)
        XCTAssertEqual(result.source, .daemon)
    }
}
