import XCTest
@testable import WhirrCore

final class VerdictSelectorTests: XCTestCase {
    private func ctx(
        _ title: String,
        _ severity: Severity = .warning,
        seconds: Int = 600,
        tier: Diagnosis.Tier = .problem,
        area: Diagnosis.Area = .mac,
        kind: Diagnosis.Kind = .standalone,
        action: SuggestedAction? = nil
    ) -> DiagnosisContext {
        DiagnosisContext(
            diagnosis: Diagnosis(title: title, detail: "", severity: severity, kind: kind,
                                 tier: tier, area: area, action: action),
            firstSeenAt: Date(timeIntervalSince1970: 0),
            durationSeconds: seconds,
            trend: .stable
        )
    }

    private func select(_ cs: [DiagnosisContext], hidden: Set<String> = []) -> Verdict {
        VerdictSelector.select(cs, isHidden: { hidden.contains($0) })
    }

    func testAllClearWhenNothingActive() {
        let v = select([])
        XCTAssertNil(v.headline)
        XCTAssertEqual(v.worst, .ok)
    }

    func testNotesNeverHeadlineOrColor() {
        let v = select([ctx("swap", .warning, tier: .note)])
        XCTAssertNil(v.headline)
        XCTAssertEqual(v.worst, .ok)
        XCTAssertNil(v.areaSeverity[.mac])
    }

    func testProblemNeedsTwoMinutesBeforeItHeadlines() {
        XCTAssertNil(select([ctx("A", seconds: 60)]).headline)
        XCTAssertEqual(select([ctx("A", seconds: 130)]).headline?.diagnosis.title, "A")
    }

    func testHigherSeverityWins() {
        let v = select([ctx("warn", .warning), ctx("crit", .critical, seconds: 200)])
        XCTAssertEqual(v.headline?.diagnosis.title, "crit")
        XCTAssertEqual(v.also.map(\.diagnosis.title), ["warn"])
        XCTAssertEqual(v.worst, .critical)
    }

    func testTieOnSeverityGoesToLongerDuration() {
        let v = select([ctx("short", .critical, seconds: 200), ctx("long", .critical, seconds: 900)])
        XCTAssertEqual(v.headline?.diagnosis.title, "long")
    }

    func testFullTieGoesToNarrativeThenTitleDeterministically() {
        let v1 = select([ctx("B"), ctx("A"), ctx("N", kind: .narrative)])
        XCTAssertEqual(v1.headline?.diagnosis.title, "N")
        let v2 = select([ctx("B"), ctx("A")])
        let v3 = select([ctx("A"), ctx("B")])
        XCTAssertEqual(v2.headline?.diagnosis.title, "A")
        XCTAssertEqual(v3.headline?.diagnosis.title, "A")
    }

    func testHiddenExcluded() {
        let v = select([ctx("A", .critical)], hidden: ["A"])
        XCTAssertNil(v.headline)
        XCTAssertEqual(v.worst, .ok)
    }

    func testAreaSeverityPerArea() {
        let v = select([ctx("m", .warning, area: .mac), ctx("c", .critical, area: .connection),
                        ctx("young", .critical, seconds: 10, area: .developer)])
        XCTAssertEqual(v.areaSeverity[.mac], .warning)
        XCTAssertEqual(v.areaSeverity[.connection], .critical)
        XCTAssertNil(v.areaSeverity[.developer])
    }

    func testShouldNotifyRequiresCriticalSustainedActionableProblem() {
        let act = SuggestedAction(label: "x", kind: .stopDocker)
        XCTAssertTrue(VerdictSelector.shouldNotify(ctx("A", .critical, seconds: 300, action: act)))
        XCTAssertFalse(VerdictSelector.shouldNotify(ctx("A", .warning, seconds: 300, action: act)))
        XCTAssertFalse(VerdictSelector.shouldNotify(ctx("A", .critical, seconds: 299, action: act)))
        XCTAssertFalse(VerdictSelector.shouldNotify(ctx("A", .critical, seconds: 300)))
        XCTAssertFalse(VerdictSelector.shouldNotify(ctx("A", .critical, seconds: 300, tier: .note, action: act)))
    }

    func testYoungProblemsArePendingNotAllClear() {
        let v = select([ctx("young", .critical, seconds: 10), ctx("note", seconds: 10, tier: .note)])
        XCTAssertNil(v.headline)
        XCTAssertEqual(v.pending.map(\.diagnosis.title), ["young"])
        XCTAssertFalse(v.isAllClear)
        XCTAssertTrue(select([]).isAllClear)
    }

    func testHiddenYoungProblemIsNotPending() {
        XCTAssertTrue(select([ctx("young", seconds: 10)], hidden: ["young"]).pending.isEmpty)
    }
}
