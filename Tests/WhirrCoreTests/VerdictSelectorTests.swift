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
        action: SuggestedAction? = nil,
        peak: Severity? = nil
    ) -> DiagnosisContext {
        DiagnosisContext(
            diagnosis: Diagnosis(title: title, detail: "", severity: severity, kind: kind,
                                 tier: tier, area: area, action: action),
            firstSeenAt: Date(timeIntervalSince1970: 0),
            durationSeconds: seconds,
            trend: .stable,
            peakSeverity: peak
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

    func testOscillatingSeverityDoesNotFlapTheHeadline() {
        // Review Focus 5: a long-running problem dipping to warning must not
        // hand the headline to a newer steady critical and back each tick.
        let dipped = select([ctx("memory", .warning, seconds: 1200, peak: .critical), ctx("disk", .critical, seconds: 300)])
        let peaked = select([ctx("memory", .critical, seconds: 1203, peak: .critical), ctx("disk", .critical, seconds: 303)])
        XCTAssertEqual(dipped.headline?.diagnosis.title, "memory")
        XCTAssertEqual(peaked.headline?.diagnosis.title, "memory")
    }

    // MARK: Stories

    private func culprit(_ title: String, _ sev: Severity, _ who: String, seconds: Int = 600) -> DiagnosisContext {
        DiagnosisContext(diagnosis: Diagnosis(title: title, detail: "", severity: sev, culprits: [who]),
                         firstSeenAt: Date(timeIntervalSince1970: 0), durationSeconds: seconds, trend: .stable, peakSeverity: sev)
    }

    func testHiddenHeadlineHandsOverToAVisibleMember() {
        let v = select([culprit("Big", .critical, "X"), culprit("Small", .warning, "X")], hidden: ["Big"])
        XCTAssertEqual(v.headline?.diagnosis.title, "Small")
        XCTAssertEqual(v.stories.count, 1)
    }

    func testStoryGoneOnlyWhenEveryMemberIsHidden() {
        XCTAssertTrue(select([culprit("Big", .critical, "X"), culprit("Small", .warning, "X")],
                             hidden: ["Big", "Small"]).stories.isEmpty)
    }

    func testVerdictCarriesTheSentence() {
        let v = select([ctx(DiagnosisTitles.overloaded, .critical)])
        XCTAssertEqual(v.sentence, "Your Mac is overloaded.")
        XCTAssertNil(select([]).sentence)
    }

    func testNotifyPerStory() {
        let act = SuggestedAction(label: "x", kind: .stopDocker)
        let story = StoryBuilder.build([ctx("A", .critical, seconds: 300, action: act)], load: .empty)[0]
        XCTAssertTrue(VerdictSelector.shouldNotify(story))
    }
}
