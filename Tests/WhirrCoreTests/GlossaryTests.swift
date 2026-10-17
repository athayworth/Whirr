import XCTest
@testable import WhirrCore

final class GlossaryTests: XCTestCase {
    func testEveryTermHasTitleShortAndDetail() {
        for term in Glossary.Term.allCases {
            XCTAssertFalse(term.title.isEmpty, "\(term)")
            XCTAssertFalse(term.short.isEmpty, "\(term)")
            XCTAssertFalse(term.detail.isEmpty, "\(term)")
            XCTAssertNotEqual(term.short, term.detail, "\(term)")
        }
    }

    func testShortsFitATooltip() {
        for term in Glossary.Term.allCases {
            XCTAssertLessThanOrEqual(term.short.count, 170, "\(term): \(term.short.count) chars")
        }
    }

    func testTitlesAreDistinct() {
        let titles = Glossary.Term.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
    }

    func testEveryTermBelongsToAGroupAndGroupsCoverAll() {
        let grouped = Glossary.Group.allCases.flatMap(\.terms)
        XCTAssertEqual(Set(grouped), Set(Glossary.Term.allCases))
        XCTAssertEqual(grouped.count, Glossary.Term.allCases.count)
    }

    func testNumbersInTheGlossaryMatchWhatWhirrUses() {
        // The glossary must teach the same lines the findings use.
        let config = ConnectionRuleConfig()
        XCTAssertTrue(Glossary.Term.snr.short.contains("\(config.weakSnr) dB"))
        XCTAssertTrue(Glossary.Term.crowding.detail.contains("\(ConnectionReportCard.loudRssi) dBm"))
        XCTAssertTrue(Glossary.Term.diskSpace.detail.contains("\(Int(LowDiskSpaceRuleConfig().warningFreeGB)) GB"))
        XCTAssertTrue(Glossary.Term.outage.short.contains("\(Int(OutageDetector.minDuration)) seconds"))
    }
}
