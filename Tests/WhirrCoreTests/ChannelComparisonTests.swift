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
                         network: String = "home", hour: Int = 19) -> [MinuteAggregate] {
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1 + day, hour: hour))!
        return (0..<minutes).map { m in
            MinuteAggregate(
                minute: start.addingTimeInterval(Double(m) * 60), networkId: network,
                gateway: HopStats(count: 30, medianMs: 3, p95Ms: 5, jitterMs: 1, lossPercent: 0, spikes: spikesPerMinute),
                internet: .empty, channel: channel, band: "5 GHz", rssi: -60, noise: -90)
        }
    }

    private func compute(_ aggs: [MinuteAggregate], current: Int? = 36, period: ChannelComparison.Period = .evening) -> ChannelComparison {
        ChannelComparison.compute(aggs, networkId: "home", currentChannel: current, period: period, calendar: calendar)
    }

    func testChannelNeedsThreeSessionsToQualify() {
        let aggs = evening(day: 0, channel: 36) + evening(day: 1, channel: 36)
        let c = compute(aggs)
        XCTAssertTrue(c.qualified.isEmpty)
        XCTAssertEqual(c.insufficient, [ChannelNeed(channel: 36, sessionsNeeded: 1)])
    }

    func testSessionNeedsThirtyMinutes() {
        let aggs = (0..<3).flatMap { evening(day: $0, channel: 36, minutes: 29) }
        XCTAssertTrue(compute(aggs).qualified.isEmpty)
    }

    func testSpikesPerHourAndOrdering() {
        let quiet = (0..<4).flatMap { evening(day: $0, channel: 36, spikesPerMinute: 0) }
        let busy = (4..<7).flatMap { evening(day: $0, channel: 149, minutes: 60, spikesPerMinute: 1) }
        let c = compute(quiet + busy)
        XCTAssertEqual(c.qualified.map(\.channel), [36, 149])
        XCTAssertEqual(c.qualified[0].sessions, 4)
        XCTAssertEqual(c.qualified[1].spikesPerHour, 60, accuracy: 0.001)
    }

    func testOtherNetworksAndOtherHoursExcluded() {
        let home = (0..<3).flatMap { evening(day: $0, channel: 36) }
        let cafe = (0..<3).flatMap { evening(day: $0, channel: 149, network: "cafe") }
        let morning = (0..<3).flatMap { evening(day: $0, channel: 11, hour: 7) }
        let c = compute(home + cafe + morning)
        XCTAssertEqual(c.qualified.map(\.channel), [36])
        XCTAssertTrue(c.insufficient.isEmpty)
    }

    func testDaytimePeriod() {
        let day = (0..<3).flatMap { evening(day: $0, channel: 44, hour: 10) }
        XCTAssertEqual(compute(day, period: .daytime).qualified.map(\.channel), [44])
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
}
