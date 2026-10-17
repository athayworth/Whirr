import XCTest
@testable import WhirrCore

final class DaySummaryTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    private var morning: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 8))! }

    private func hop(_ spikes: Int, count: Int = 30, loss: Double = 0) -> HopStats {
        HopStats(count: count, medianMs: count > 0 ? 3 : nil, p95Ms: nil, jitterMs: nil, lossPercent: loss, spikes: spikes)
    }

    /// `minutes` aggregates starting at 08:00 today.
    private func day(minutes: Int, gateway: (Int) -> HopStats, internet: (Int) -> HopStats,
                     start: Date? = nil, network: String = "home") -> [MinuteAggregate] {
        (0..<minutes).map { m in
            MinuteAggregate(minute: (start ?? morning).addingTimeInterval(Double(m) * 60), networkId: network,
                            gateway: gateway(m), internet: internet(m), channel: 36, band: "5 GHz",
                            rssi: -60, noise: -90, widthMHz: 80)
        }
    }

    private func summary(_ aggs: [MinuteAggregate], hoursLater: Double = 4) -> DaySummary {
        DaySummary.compute(aggs, networkId: "home", now: morning.addingTimeInterval(hoursLater * 3600), calendar: calendar)
    }

    func testNotEnoughData() {
        let s = summary(day(minutes: 20, gateway: { _ in self.hop(0) }, internet: { _ in self.hop(0) }))
        XCTAssertEqual(s.verdict, .notEnoughData)
        XCTAssertTrue(s.sentence.contains("20 minutes"), s.sentence)
    }

    func testSteadyBothSides() {
        let s = summary(day(minutes: 120, gateway: { _ in self.hop(0) }, internet: { _ in self.hop(0) }))
        XCTAssertEqual(s.verdict, .steady)
    }

    func testStallsBeyondRouterDoNotBlameTheProvider() {
        // 1 stall a minute beyond the router = 60/hour; router hop clean.
        let s = summary(day(minutes: 120, gateway: { _ in self.hop(0) }, internet: { _ in self.hop(1) }))
        XCTAssertEqual(s.verdict, .beyondRouter)
        XCTAssertTrue(s.sentence.contains("120"), s.sentence)
        XCTAssertFalse(s.sentence.contains("provider"), s.sentence)
    }

    func testRouterHopStallsAreInsideTheHome() {
        let s = summary(day(minutes: 120, gateway: { _ in self.hop(1) }, internet: { _ in self.hop(1) }))
        XCTAssertEqual(s.verdict, .insideHome)
        XCTAssertFalse(s.sentence.contains("beyond it stalled"), s.sentence)
    }

    func testOccasionalStallsStillCountAsSteady() {
        // 10 stalls over 2 hours = 5/hour, under the 18/hour line.
        let s = summary(day(minutes: 120, gateway: { $0 % 12 == 0 ? self.hop(1) : self.hop(0) },
                            internet: { _ in self.hop(0) }))
        XCTAssertEqual(s.verdict, .steady)
        XCTAssertTrue(s.sentence.contains("10"), s.sentence)
    }

    func testRouterNeverAnsweredCantSeparate() {
        let s = summary(day(minutes: 120, gateway: { _ in self.hop(0, count: 0) }, internet: { _ in self.hop(1) }))
        XCTAssertEqual(s.verdict, .cantSeparate)
        XCTAssertTrue(s.sentence.contains("can't tell"), s.sentence)
    }

    func testYesterdayAndOtherNetworksExcluded() {
        let yesterday = day(minutes: 120, gateway: { _ in self.hop(5) }, internet: { _ in self.hop(5) },
                            start: morning.addingTimeInterval(-86_400))
        let cafe = day(minutes: 120, gateway: { _ in self.hop(5) }, internet: { _ in self.hop(5) }, network: "cafe")
        let today = day(minutes: 60, gateway: { _ in self.hop(0) }, internet: { _ in self.hop(0) })
        let s = summary(yesterday + cafe + today)
        XCTAssertEqual(s.verdict, .steady)
        XCTAssertEqual(s.minutesWatched, 60)
    }

    func testLossAloneMakesAHopUnsteady() {
        let s = summary(day(minutes: 120, gateway: { _ in self.hop(0) }, internet: { _ in self.hop(0, loss: 3) }))
        XCTAssertEqual(s.verdict, .beyondRouter)
    }
}
