import XCTest
@testable import WhirrCore

/// Checks that a finding's "How Whirr knows" only states numbers that
/// came from the inputs the test fed in — nothing invented.
enum EvidenceAccuracy {
    static func numbers(in s: String) -> [Double] {
        let regex = try! NSRegularExpression(pattern: #"-?\d+(\.\d+)?"#)
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range, in: s).flatMap { Double(s[$0]) }
        }
    }

    static func assertAllNumbers(_ d: Diagnosis?, from inputs: [Double],
                                 file: StaticString = #filePath, line: UInt = #line) {
        guard let d else { return XCTFail("no diagnosis", file: file, line: line) }
        XCTAssertFalse(d.evidence.isEmpty, "\(d.title) has no evidence", file: file, line: line)
        for n in d.evidence.flatMap(numbers(in:)) {
            XCTAssertTrue(inputs.contains { abs($0 - n) <= 0.5 },
                          "\(d.title): \(n) not from inputs \(inputs) — evidence: \(d.evidence)", file: file, line: line)
        }
    }
}
