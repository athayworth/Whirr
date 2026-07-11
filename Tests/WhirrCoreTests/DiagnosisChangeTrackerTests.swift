import XCTest
@testable import WhirrCore

final class DiagnosisChangeTrackerTests: XCTestCase {
    private func diagnosis(_ title: String, _ severity: Severity) -> Diagnosis {
        Diagnosis(title: title, detail: "", severity: severity)
    }

    func testFirstCriticalDiagnosisFires() {
        var tracker = DiagnosisChangeTracker()
        let result = tracker.newlyCritical(in: [diagnosis("Memory is saturated", .critical)])
        XCTAssertEqual(result.map(\.title), ["Memory is saturated"])
    }

    func testSameDiagnosisDoesNotFireTwice() {
        var tracker = DiagnosisChangeTracker()
        _ = tracker.newlyCritical(in: [diagnosis("Memory is saturated", .critical)])
        let second = tracker.newlyCritical(in: [diagnosis("Memory is saturated", .critical)])
        XCTAssertEqual(second, [])
    }

    func testDiagnosisStaysSilentWhileContinuouslyCritical() {
        // Critical conditions that persist don't repeatedly notify — one
        // alert per firing, even hours later.
        var tracker = DiagnosisChangeTracker(cooldown: 100)
        let t0 = Date()
        _ = tracker.newlyCritical(in: [diagnosis("A", .critical)], now: t0)
        let later = tracker.newlyCritical(
            in: [diagnosis("A", .critical)],
            now: t0.addingTimeInterval(10_000)
        )
        XCTAssertEqual(later, [])
    }

    func testBriefFlapDoesNotReNotify() {
        // A condition that briefly clears and returns within the cooldown
        // window is suppressed — we don't want notification storms on
        // borderline-critical states that flap on and off.
        var tracker = DiagnosisChangeTracker(cooldown: 100)
        let t0 = Date()
        _ = tracker.newlyCritical(in: [diagnosis("A", .critical)], now: t0)
        _ = tracker.newlyCritical(in: [], now: t0.addingTimeInterval(10))
        let flap = tracker.newlyCritical(
            in: [diagnosis("A", .critical)],
            now: t0.addingTimeInterval(20)
        )
        XCTAssertEqual(flap, [])
    }

    func testReFiresAfterCleanClearPastCooldown() {
        var tracker = DiagnosisChangeTracker(cooldown: 100)
        let t0 = Date()
        _ = tracker.newlyCritical(in: [diagnosis("A", .critical)], now: t0)
        // Condition stays clear past the cooldown window.
        _ = tracker.newlyCritical(in: [], now: t0.addingTimeInterval(200))
        // Comes back — fires again because the cooldown lapsed and the
        // condition was inactive at lapse time.
        let returned = tracker.newlyCritical(
            in: [diagnosis("A", .critical)],
            now: t0.addingTimeInterval(250)
        )
        XCTAssertEqual(returned.map(\.title), ["A"])
    }

    func testNonCriticalDiagnosesAreIgnored() {
        var tracker = DiagnosisChangeTracker()
        let result = tracker.newlyCritical(in: [
            diagnosis("Memory is tight", .warning),
            diagnosis("Backup is using your system", .ok)
        ])
        XCTAssertEqual(result, [])
    }

    // MARK: - Recovery detection

    func testNewlyClearedReportsPreviouslyCriticalTitlesNoLongerFiring() {
        // First tick: A and B critical → both recorded as previous.
        var tracker = DiagnosisChangeTracker()
        _ = tracker.newlyCritical(in: [diagnosis("A", .critical), diagnosis("B", .critical)])
        // Second tick: A cleared, B still critical → newlyCleared should
        // report A. Order matters: newlyCleared must be read BEFORE
        // newlyCritical mutates previousCriticalKeys.
        let cleared = tracker.newlyCleared(in: [diagnosis("B", .critical)])
        XCTAssertEqual(cleared, ["A"])
    }

    func testNewlyClearedIsEmptyWhenNothingResolved() {
        var tracker = DiagnosisChangeTracker()
        _ = tracker.newlyCritical(in: [diagnosis("A", .critical)])
        let cleared = tracker.newlyCleared(in: [diagnosis("A", .critical)])
        XCTAssertEqual(cleared, [])
    }

    func testDifferentDiagnosesTrackedIndependently() {
        var tracker = DiagnosisChangeTracker()
        let first = tracker.newlyCritical(in: [diagnosis("A", .critical)])
        XCTAssertEqual(first.map(\.title), ["A"])
        let second = tracker.newlyCritical(in: [
            diagnosis("A", .critical),
            diagnosis("B", .critical)
        ])
        XCTAssertEqual(second.map(\.title), ["B"])
    }
}
