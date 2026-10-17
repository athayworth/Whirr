import XCTest
@testable import WhirrCore

final class ChannelChangeLogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func agg(_ minute: Int, channel: Int?, band: String? = "5 GHz", width: Int? = 80,
                     network: String = "home") -> MinuteAggregate {
        MinuteAggregate(minute: t0.addingTimeInterval(Double(minute) * 60), networkId: network,
                        gateway: .empty, internet: .empty, channel: channel, band: channel == nil ? nil : band,
                        rssi: nil, noise: nil, widthMHz: channel == nil ? nil : width)
    }

    private func changes(_ aggs: [MinuteAggregate]) -> [ChannelChange] {
        ChannelChangeLog.changes(aggs, networkId: "home")
    }

    func testNoChangeNoEntries() {
        XCTAssertTrue(changes((0..<10).map { agg($0, channel: 36) }).isEmpty)
    }

    func testChangeBetweenConsecutiveMinutesIsExact() {
        let c = changes([agg(0, channel: 36), agg(1, channel: 36), agg(2, channel: 157)])
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].at, t0.addingTimeInterval(120))
        XCTAssertNil(c[0].notBefore)
        XCTAssertEqual(c[0].description, "Your Mac's Wi-Fi moved from 5 GHz channel 36 to channel 157.")
    }

    func testChangeAcrossAGapIsReportedAsAWindow() {
        // Whirr wasn't running from minute 1 to minute 30.
        let c = changes([agg(0, channel: 36), agg(30, channel: 157)])
        XCTAssertEqual(c[0].notBefore, t0.addingTimeInterval(60))
        XCTAssertEqual(c[0].at, t0.addingTimeInterval(30 * 60))
    }

    func testWiFiOffInBetweenStillComparesLastKnownLink() {
        let c = changes([agg(0, channel: 36), agg(1, channel: nil), agg(2, channel: nil), agg(3, channel: 157)])
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].notBefore, t0.addingTimeInterval(60))
    }

    func testBandSwitchIsWordedAsTheMacSwitchingBand() {
        let c = changes([agg(0, channel: 157), agg(1, channel: 6, band: "2.4 GHz", width: 20)])
        XCTAssertEqual(c[0].description, "Your Mac switched from 5 GHz (channel 157) to 2.4 GHz (channel 6).")
    }

    func testWidthChangeIsMentioned() {
        let c = changes([agg(0, channel: 36, width: 80), agg(1, channel: 36, width: 40)])
        XCTAssertEqual(c[0].description, "Your Mac's Wi-Fi on 5 GHz channel 36 changed width from 80 MHz to 40 MHz.")
    }

    func testOldHistoryWithoutWidthDoesNotInventAChange() {
        XCTAssertTrue(changes([agg(0, channel: 36, width: nil), agg(1, channel: 36, width: 80)]).isEmpty)
    }

    func testOtherNetworksIgnoredAndNewestFirst() {
        let aggs = [agg(0, channel: 36), agg(1, channel: 149, network: "cafe"), agg(2, channel: 44),
                    agg(3, channel: 157)]
        let c = changes(aggs)
        XCTAssertEqual(c.map { $0.to.channel }, [157, 44])
    }
}
