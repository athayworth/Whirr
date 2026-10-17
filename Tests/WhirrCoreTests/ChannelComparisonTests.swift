import XCTest
@testable import WhirrCore

final class ChannelComparisonTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    /// `minutes` aggregates starting at 19:00 local on `day` (Oct 1 + day).
    private func evening(day: Int, channel: Int, minutes: Int = 60, spikesPerMinute: Int = 0,
                         network: String = "home", hour: Int = 19, width: Int? = 80,
                         gatewayCount: Int = 30) -> [MinuteAggregate] {
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1 + day, hour: hour))!
        return (0..<minutes).map { m in
            MinuteAggregate(
                minute: start.addingTimeInterval(Double(m) * 60), networkId: network,
                gateway: HopStats(count: gatewayCount, medianMs: gatewayCount > 0 ? 3 : nil, p95Ms: nil, jitterMs: nil,
                                  lossPercent: 0, spikes: spikesPerMinute),
                internet: .empty, channel: channel, band: "5 GHz", rssi: -60, noise: -90, widthMHz: width)
        }
    }

    private func group(_ channel: Int, _ width: Int? = 80) -> ChannelGroup {
        ChannelGroup(band: "5 GHz", channel: channel, widthMHz: width)
    }

    private func compute(_ aggs: [MinuteAggregate], current: Int? = 36, period: ChannelComparison.Period = .evening) -> ChannelComparison {
        ChannelComparison.compute(aggs, networkId: "home", current: current.map { group($0) }, period: period, calendar: calendar)
    }

    private func starts(_ stats: [ChannelStat]) -> [Int] { stats.map(\.group.channels.lowerBound) }

    func testChannelNeedsThreeSessionsToQualify() {
        let aggs = evening(day: 0, channel: 36) + evening(day: 1, channel: 36)
        let c = compute(aggs)
        XCTAssertTrue(c.qualified.isEmpty)
        XCTAssertEqual(c.insufficient, [ChannelNeed(group: group(36), sessionsNeeded: 1)])
    }

    func testSessionNeedsThirtyMinutes() {
        let aggs = (0..<3).flatMap { evening(day: $0, channel: 36, minutes: 29) }
        XCTAssertTrue(compute(aggs).qualified.isEmpty)
    }

    func testSpikesPerHourAndOrdering() {
        let quiet = (0..<4).flatMap { evening(day: $0, channel: 36, spikesPerMinute: 0) }
        let busy = (4..<7).flatMap { evening(day: $0, channel: 149, minutes: 60, spikesPerMinute: 1) }
        let c = compute(quiet + busy)
        XCTAssertEqual(starts(c.qualified), [36, 149])
        XCTAssertEqual(c.qualified[0].sessions, 4)
        XCTAssertEqual(c.qualified[1].spikesPerHour, 60, accuracy: 0.001)
    }

    func testOtherNetworksAndOtherHoursExcluded() {
        let home = (0..<3).flatMap { evening(day: $0, channel: 36) }
        let cafe = (0..<3).flatMap { evening(day: $0, channel: 149, network: "cafe") }
        let morning = (0..<3).flatMap { evening(day: $0, channel: 11, hour: 7) }
        let c = compute(home + cafe + morning)
        XCTAssertEqual(starts(c.qualified), [36])
        XCTAssertTrue(c.insufficient.isEmpty)
    }

    func testDaytimePeriod() {
        let day = (0..<3).flatMap { evening(day: $0, channel: 44, hour: 10) }
        XCTAssertEqual(starts(compute(day, period: .daytime).qualified), [36])  // 44 at 80 MHz is 36–48
        XCTAssertTrue(compute(day, period: .evening).qualified.isEmpty)
    }

    func testCurrentChannelWorsened() {
        let calm = (0..<3).flatMap { evening(day: $0, channel: 36, spikesPerMinute: 0) }
        let rough = (3..<6).flatMap { evening(day: $0, channel: 36, spikesPerMinute: 1) }
        XCTAssertTrue(compute(calm + rough).currentChannelWorsened)
        XCTAssertFalse(compute(calm + calm.map { $0 }).currentChannelWorsened)
    }

    func testWorsenedNeedsThreePriorSessions() {
        let calm = (0..<2).flatMap { evening(day: $0, channel: 36) }
        let rough = (2..<5).flatMap { evening(day: $0, channel: 36, spikesPerMinute: 1) }
        XCTAssertFalse(compute(calm + rough).currentChannelWorsened)
    }

    // MARK: Grouping by stretch of airwaves

    func testChannelsSharingAnEightyMHzBlockAreOneGroup() {
        // A router that hops 36 → 44 at 80 MHz never left channels 36–48.
        let aggs = evening(day: 0, channel: 36) + evening(day: 1, channel: 44) + evening(day: 2, channel: 40)
        let c = compute(aggs)
        XCTAssertEqual(c.qualified.count, 1)
        XCTAssertEqual(c.qualified.first?.group.label, "5 GHz channels 36–48")
        XCTAssertEqual(c.qualified.first?.sessions, 3)
    }

    func testDifferentWidthsOnTheSameChannelAreDifferentGroups() {
        let aggs = (0..<3).flatMap { evening(day: $0, channel: 36, width: 80) }
            + (3..<6).flatMap { evening(day: $0, channel: 36, width: 20) }
        XCTAssertEqual(compute(aggs).qualified.count, 2)
    }

    func testOldHistoryWithoutWidthIsKeptSeparateAndSaysSo() {
        let aggs = (0..<3).flatMap { evening(day: $0, channel: 36, width: nil) }
        let c = compute(aggs, current: nil)
        XCTAssertEqual(c.qualified.first?.group.label, "5 GHz channel 36 (width not recorded)")
    }

    func testMinutesWithoutRouterDataDoNotDiluteTheRate() {
        // 30 measured minutes with 1 stall each + 30 unmeasured minutes:
        // 60 stalls/hour, not 30.
        let aggs = (0..<3).flatMap { evening(day: $0, channel: 36, minutes: 30, spikesPerMinute: 1)
            + evening(day: $0, channel: 36, minutes: 30, hour: 20, gatewayCount: 0) }
        XCTAssertEqual(compute(aggs).qualified.first?.spikesPerHour ?? 0, 60, accuracy: 0.001)
    }

    func testCurrentGroupMarkerUsesTheBlock() {
        let calm = (0..<3).flatMap { evening(day: $0, channel: 36) }
        let rough = (3..<6).flatMap { evening(day: $0, channel: 44, spikesPerMinute: 1) }
        // Current link on 40 at 80 MHz is the same block.
        XCTAssertTrue(compute(calm + rough, current: 40).currentChannelWorsened)
    }
}
