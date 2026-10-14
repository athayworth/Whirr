import XCTest
@testable import WhirrCore

final class NetworkQualityParseTests: XCTestCase {
    func testParsesRealOutputShape() {
        let json = #"{"base_rtt":22.74,"dl_throughput":198652512,"ul_throughput":31121992,"responsiveness":568.43,"interface_name":"en0","other":{}}"#
        let r = ConnectionTestRunner.parse(networkQualityJSON: Data(json.utf8))
        XCTAssertEqual(r?.downMbps ?? 0, 198.65, accuracy: 0.01)
        XCTAssertEqual(r?.upMbps ?? 0, 31.12, accuracy: 0.01)
        XCTAssertEqual(r?.idleLatencyMs ?? 0, 22.74, accuracy: 0.01)
        XCTAssertEqual(r?.loadedLatencyMs ?? 0, 60_000 / 568.43, accuracy: 0.01)
    }

    func testMissingFieldsBecomeNil() {
        let r = ConnectionTestRunner.parse(networkQualityJSON: Data(#"{"base_rtt":20}"#.utf8))
        XCTAssertNil(r?.downMbps)
        XCTAssertNil(r?.loadedLatencyMs)
        XCTAssertEqual(r?.idleLatencyMs, 20)
    }

    func testGarbageIsNil() {
        XCTAssertNil(ConnectionTestRunner.parse(networkQualityJSON: Data("nope".utf8)))
    }
}
