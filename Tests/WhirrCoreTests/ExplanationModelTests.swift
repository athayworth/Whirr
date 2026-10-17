import XCTest
@testable import WhirrCore

final class ExplanationModelTests: XCTestCase {
    func testExplainedKeepsIdentityAndAddsWhy() {
        let d = Diagnosis(title: "T", detail: "d", severity: .warning)
        let e = d.explained(evidence: ["A 1", "B 2"], impact: "Because.")
        XCTAssertEqual(e.id, d.id)
        XCTAssertEqual(e.evidence, ["A 1", "B 2"])
        XCTAssertEqual(e.impact, "Because.")
        // classified() must carry the explanation through.
        XCTAssertEqual(e.classified(tier: .note, area: .mac, action: nil).evidence, ["A 1", "B 2"])
    }

    func testOldPayloadsDecodeWithEmptyExplanation() throws {
        let json = #"{"id":"7E3F1C2A-1111-4222-8333-444455556666","title":"T","detail":"d","severity":1}"#
        let d = try JSONDecoder().decode(Diagnosis.self, from: Data(json.utf8))
        XCTAssertEqual(d.evidence, [])
        XCTAssertNil(d.impact)
    }

    func testOldIncidentsDecodeAndClassifyByTitle() throws {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        func incident(_ title: String) throws -> DiagnosisIncident {
            let json = #"{"id":"7E3F1C2A-1111-4222-8333-444455556666","title":"\#(title)","peakSeverity":1,"firstSeenAt":"2026-10-15T06:00:00Z","lastSeenAt":"2026-10-15T07:00:00Z"}"#
            return try d.decode(DiagnosisIncident.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try incident("Swap is holding old pages").tier, .note)
        XCTAssertEqual(try incident("Big processes that look unused").tier, .note)
        XCTAssertEqual(try incident("Docker is using significant resources").tier, .note)
        XCTAssertEqual(try incident("System is overloaded").tier, .problem)
        XCTAssertEqual(try incident("Your link to the router is stalling").area, .connection)
        XCTAssertEqual(try incident("System is overloaded").area, .mac)
    }

    func testTrackerRecordsTierAndAreaOnClosedIncidents() {
        var t = DiagnosisDurationTracker()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let d = Diagnosis(title: "X", detail: "", severity: .warning, tier: .note, area: .developer)
        _ = t.annotate([d], now: t0)
        let closed = t.annotate([], now: t0.addingTimeInterval(3600)).closedIncidents
        XCTAssertEqual(closed.first?.tier, .note)
        XCTAssertEqual(closed.first?.area, .developer)
    }

    func testDurationWords() {
        XCTAssertEqual(DurationText.words(seconds: 45), "45 s")
        XCTAssertEqual(DurationText.words(seconds: 999), "16 min")
        XCTAssertEqual(DurationText.words(seconds: 4200), "1 h 10 min")
        XCTAssertEqual(DurationText.words(seconds: 7200), "2 h")
    }
}
