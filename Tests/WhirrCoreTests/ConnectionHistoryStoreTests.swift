import XCTest
@testable import WhirrCore

final class ConnectionHistoryStoreTests: XCTestCase {
    private var dir: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("WhirrConnStore-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func agg(_ offset: TimeInterval, network: String = "home") -> MinuteAggregate {
        MinuteAggregate(minute: t0.addingTimeInterval(offset), networkId: network,
                        gateway: .empty, internet: .empty, channel: 36, band: "5 GHz", rssi: -60, noise: -90)
    }

    func testAppendAndReadAggregatesAcrossInstances() {
        ConnectionHistoryStore(directory: dir).append(agg(0))
        ConnectionHistoryStore(directory: dir).append(agg(60))
        let all = ConnectionHistoryStore(directory: dir).aggregates(since: .distantPast)
        XCTAssertEqual(all.map(\.minute), [t0, t0.addingTimeInterval(60)])
    }

    func testAggregatesSinceFilters() {
        let store = ConnectionHistoryStore(directory: dir)
        store.append(agg(0)); store.append(agg(120))
        XCTAssertEqual(store.aggregates(since: t0.addingTimeInterval(60)).count, 1)
    }

    func testPurgeRemovesOldAggregatesAndOutages() {
        let store = ConnectionHistoryStore(directory: dir)
        store.append(agg(0)); store.append(agg(86_400))
        store.appendOutage(OutageRecord(start: t0, end: t0.addingTimeInterval(20), cause: .isp, networkId: "home"))
        store.purge(olderThan: t0.addingTimeInterval(3600))
        XCTAssertEqual(store.aggregates(since: .distantPast).count, 1)
        XCTAssertTrue(store.outages().isEmpty)
    }

    func testOutageAppendThenUpdate() {
        let store = ConnectionHistoryStore(directory: dir)
        var o = OutageRecord(start: t0, cause: .router, networkId: "home")
        store.appendOutage(o)
        o.end = t0.addingTimeInterval(30)
        store.updateOutage(o)
        XCTAssertEqual(ConnectionHistoryStore(directory: dir).outages(), [o])
    }

    func testCorruptLineIsSkipped() throws {
        let store = ConnectionHistoryStore(directory: dir)
        store.append(agg(0))
        let handle = try FileHandle(forWritingTo: dir.appendingPathComponent("connection-history.jsonl"))
        handle.seekToEndOfFile(); handle.write(Data("{garbage\n".utf8)); try handle.close()
        store.append(agg(60))
        XCTAssertEqual(store.aggregates(since: .distantPast).count, 2)
    }
}

extension ConnectionHistoryStoreTests {
    func testSavedTestsRoundTripNewestLastCappedAtFifty() {
        let store = ConnectionHistoryStore(directory: dir)
        for i in 0..<55 {
            store.saveTest(ConnectionTestResult(at: t0.addingTimeInterval(Double(i)), networkId: "home", nq: nil,
                                                gatewayIdle: .empty, gatewayLoaded: .empty, link: nil, neighbors: []))
        }
        let tests = ConnectionHistoryStore(directory: dir).tests()
        XCTAssertEqual(tests.count, 50)
        XCTAssertEqual(tests.last?.at, t0.addingTimeInterval(54))
    }
}

extension ConnectionHistoryStoreTests {
    func testCloseDanglingOutagesEndsOpenRecords() {
        let store = ConnectionHistoryStore(directory: dir)
        store.appendOutage(OutageRecord(start: t0, cause: .isp, networkId: "home"))
        store.appendOutage(OutageRecord(start: t0, end: t0.addingTimeInterval(20), cause: .router, networkId: "home"))
        store.closeDanglingOutages(at: t0.addingTimeInterval(300))
        let all = store.outages()
        XCTAssertTrue(all.allSatisfy { $0.end != nil })
        XCTAssertEqual(all.first?.end, t0.addingTimeInterval(300))
        XCTAssertEqual(all.last?.end, t0.addingTimeInterval(20))
    }
}
