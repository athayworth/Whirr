import XCTest
@testable import WhirrCore

final class ConnectionStatsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func feed(_ stats: inout ConnectionStats, _ rtts: [Double?], hop: Hop = .gateway, network: String = "home", start: TimeInterval = 0) {
        for (i, rtt) in rtts.enumerated() {
            stats.record(PingSample(at: t0.addingTimeInterval(start + Double(i) * 2), hop: hop, rttMs: rtt), networkId: network)
        }
    }

    func testMedianAndP95() {
        var s = ConnectionStats()
        feed(&s, (1...20).map { Double($0) })
        let r = s.stats(hop: .gateway, window: 3600, now: t0.addingTimeInterval(40))
        XCTAssertEqual(r.count, 20)
        XCTAssertEqual(r.medianMs!, 10.5, accuracy: 0.001)
        XCTAssertEqual(r.p95Ms!, 19, accuracy: 0.001)
    }

    func testLossPercentCountsTimeouts() {
        var s = ConnectionStats()
        feed(&s, [5, nil, 5, 5])
        XCTAssertEqual(s.stats(hop: .gateway, window: 3600, now: t0.addingTimeInterval(10)).lossPercent, 25, accuracy: 0.001)
    }

    func testJitterIsMeanAbsoluteSuccessiveDifference() {
        var s = ConnectionStats()
        feed(&s, [10, 20, 10, 20])
        XCTAssertEqual(s.stats(hop: .gateway, window: 3600, now: t0.addingTimeInterval(10)).jitterMs!, 10, accuracy: 0.001)
    }

    func testSpikeThresholds() {
        XCTAssertTrue(ConnectionStats.isSpike(60, median: 5))
        XCTAssertFalse(ConnectionStats.isSpike(40, median: 5))
        XCTAssertTrue(ConnectionStats.isSpike(95, median: 30))
        XCTAssertFalse(ConnectionStats.isSpike(85, median: 30))
        XCTAssertTrue(ConnectionStats.isSpike(nil, median: 5))
    }

    func testSpikeCountUsesWindowMedian() {
        var s = ConnectionStats()
        feed(&s, [3, 3, 3, 195, 3, 3, nil, 3])
        XCTAssertEqual(s.stats(hop: .gateway, window: 3600, now: t0.addingTimeInterval(20)).spikes, 2)
    }

    func testWindowExcludesOlderSamples() {
        var s = ConnectionStats()
        feed(&s, [100, 100, 100])                  // t0..t4
        feed(&s, [5, 5, 5], start: 120)            // t120..t124
        let r = s.stats(hop: .gateway, window: 60, now: t0.addingTimeInterval(125))
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r.medianMs!, 5, accuracy: 0.001)
    }

    func testHopsAreSeparate() {
        var s = ConnectionStats()
        feed(&s, [5, 5], hop: .gateway)
        feed(&s, [30], hop: .internet)
        XCTAssertEqual(s.stats(hop: .internet, window: 3600, now: t0.addingTimeInterval(10)).count, 1)
    }

    func testNetworkChangeClearsSamples() {
        var s = ConnectionStats()
        feed(&s, [100, 100, 100], network: "home")
        feed(&s, [5], network: "hotspot", start: 10)
        let r = s.stats(hop: .gateway, window: 3600, now: t0.addingTimeInterval(20))
        XCTAssertEqual(r.count, 1)
    }

    func testEmptyWindowHasNoMedianAndZeroLoss() {
        let r = ConnectionStats().stats(hop: .gateway, window: 60, now: t0)
        XCTAssertEqual(r.count, 0)
        XCTAssertNil(r.medianMs)
        XCTAssertEqual(r.lossPercent, 0)
    }

    func testRetentionDropsOldSamples() {
        var s = ConnectionStats(retention: 60)
        feed(&s, [5])
        feed(&s, [5], start: 200)
        XCTAssertEqual(s.stats(hop: .gateway, window: 100_000, now: t0.addingTimeInterval(200)).count, 1)
    }
}
