import XCTest
@testable import WhirrCore

/// The duration tracker is what turns a persistent red badge into
/// something intelligible — the difference between "just fired 2s ago,
/// worsening" and "on for 40 min, stable." These tests pin down the
/// clock behavior (streak preservation across brief flaps; reset after
/// a clear window; trend polarity).
final class DiagnosisDurationTrackerTests: XCTestCase {
    private func diagnosis(_ title: String, _ severity: Severity = .warning) -> Diagnosis {
        Diagnosis(title: title, detail: "", severity: severity)
    }

    func testFirstAppearanceHasZeroDurationAndStableTrend() {
        var tracker = DiagnosisDurationTracker()
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let contexts = tracker.annotate([diagnosis("A")], now: now).contexts
        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts[0].durationSeconds, 0)
        XCTAssertEqual(contexts[0].trend, .stable)
    }

    func testDurationGrowsAcrossTicks() {
        var tracker = DiagnosisDurationTracker()
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        _ = tracker.annotate([diagnosis("A")], now: start)
        let contexts = tracker.annotate(
            [diagnosis("A")],
            now: start.addingTimeInterval(30)
        ).contexts
        XCTAssertEqual(contexts[0].durationSeconds, 30)
    }

    func testBriefAbsencePreservesStreak() {
        // A single tick where the diagnosis disappears (well within the
        // clear-reset window) shouldn't restart the clock — the underlying
        // condition is still real, we just didn't see it this instant.
        var tracker = DiagnosisDurationTracker(clearReset: 60)
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        _ = tracker.annotate([diagnosis("A")], now: start)
        _ = tracker.annotate([], now: start.addingTimeInterval(10))
        let contexts = tracker.annotate(
            [diagnosis("A")],
            now: start.addingTimeInterval(20)
        ).contexts
        XCTAssertEqual(contexts[0].durationSeconds, 20,
                       "Streak should span the brief absence, not reset")
    }

    func testLongAbsenceResetsStreak() {
        var tracker = DiagnosisDurationTracker(clearReset: 60)
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        _ = tracker.annotate([diagnosis("A")], now: start)
        // Stay absent for well past the reset window.
        _ = tracker.annotate([], now: start.addingTimeInterval(300))
        let contexts = tracker.annotate(
            [diagnosis("A")],
            now: start.addingTimeInterval(310)
        ).contexts
        XCTAssertEqual(contexts[0].durationSeconds, 0,
                       "Long absence should restart duration counter")
    }

    func testWorseningTrendWhenSeverityRises() {
        var tracker = DiagnosisDurationTracker(trendLookback: 30)
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        _ = tracker.annotate([diagnosis("A", .warning)], now: start)
        // Enough time for the reference-severity slot to fill.
        _ = tracker.annotate([diagnosis("A", .warning)], now: start.addingTimeInterval(35))
        let contexts = tracker.annotate(
            [diagnosis("A", .critical)],
            now: start.addingTimeInterval(70)
        ).contexts
        XCTAssertEqual(contexts[0].trend, .worsening)
    }

    func testImprovingTrendWhenSeverityDrops() {
        var tracker = DiagnosisDurationTracker(trendLookback: 30)
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        _ = tracker.annotate([diagnosis("A", .critical)], now: start)
        _ = tracker.annotate([diagnosis("A", .critical)], now: start.addingTimeInterval(35))
        let contexts = tracker.annotate(
            [diagnosis("A", .warning)],
            now: start.addingTimeInterval(70)
        ).contexts
        XCTAssertEqual(contexts[0].trend, .improving)
    }

    func testStableTrendWithinLookbackWindow() {
        // Not enough time has passed for a reference sample — trend must
        // stay stable rather than guess a direction from insufficient data.
        var tracker = DiagnosisDurationTracker(trendLookback: 60)
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        _ = tracker.annotate([diagnosis("A", .warning)], now: start)
        let contexts = tracker.annotate(
            [diagnosis("A", .critical)],
            now: start.addingTimeInterval(10)
        ).contexts
        XCTAssertEqual(contexts[0].trend, .stable)
    }

    // MARK: - Closed-incident emission (feeds the Insights charts)

    func testClosedIncidentEmittedWhenTitleStopsFiringPastClearReset() {
        // Log the incident on the tick where the clear-reset window
        // expires — that's the earliest we can be confident the
        // condition is really gone rather than a sampling flap.
        var tracker = DiagnosisDurationTracker(clearReset: 60)
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        _ = tracker.annotate([diagnosis("A", .warning)], now: start)
        _ = tracker.annotate([diagnosis("A", .critical)], now: start.addingTimeInterval(10))
        let result = tracker.annotate([], now: start.addingTimeInterval(200))
        XCTAssertEqual(result.closedIncidents.count, 1)
        let incident = result.closedIncidents[0]
        XCTAssertEqual(incident.title, "A")
        XCTAssertEqual(incident.peakSeverity, .critical,
                       "Peak severity should be the worst observed, not the last")
        XCTAssertEqual(incident.firstSeenAt, start)
        XCTAssertEqual(incident.lastSeenAt, start.addingTimeInterval(10))
    }

    func testNoIncidentEmittedWhileTitleStillFiring() {
        var tracker = DiagnosisDurationTracker(clearReset: 60)
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        _ = tracker.annotate([diagnosis("A")], now: start)
        let result = tracker.annotate([diagnosis("A")], now: start.addingTimeInterval(30))
        XCTAssertEqual(result.closedIncidents, [])
    }

    func testMultipleTitlesTrackedIndependently() {
        var tracker = DiagnosisDurationTracker()
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        _ = tracker.annotate([diagnosis("A")], now: start)
        let contexts = tracker.annotate(
            [diagnosis("A"), diagnosis("B")],
            now: start.addingTimeInterval(20)
        ).contexts
        let byTitle = Dictionary(uniqueKeysWithValues: contexts.map { ($0.diagnosis.title, $0) })
        XCTAssertEqual(byTitle["A"]?.durationSeconds, 20)
        XCTAssertEqual(byTitle["B"]?.durationSeconds, 0,
                       "New title should start at zero even when others are running")
    }
}
