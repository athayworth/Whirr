import XCTest
@testable import WhirrCore

final class OutageDetectorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Feeds one observation per 2 s and collects opened/closed records.
    @discardableResult
    private func run(_ d: inout OutageDetector, from: TimeInterval, to: TimeInterval,
                     gateway: Bool?, internet: Bool, wifi: Bool = true, network: String = "home",
                     step: TimeInterval = 2) -> (opened: [OutageRecord], closed: [OutageRecord]) {
        var opened: [OutageRecord] = [], closed: [OutageRecord] = []
        var t = from
        while t <= to {
            let r = d.observe(gatewayOK: gateway, internetOK: internet, wifiAssociated: wifi,
                              at: t0.addingTimeInterval(t), networkId: network)
            if let o = r.opened { opened.append(o) }
            if let c = r.closed { closed.append(c) }
            t += step
        }
        return (opened, closed)
    }

    func testBothHopsDownTwelveSecondsIsRouterOutageFromFirstFailure() {
        var d = OutageDetector()
        run(&d, from: 0, to: 4, gateway: true, internet: true)
        let r = run(&d, from: 6, to: 18, gateway: false, internet: false)
        XCTAssertEqual(r.opened.count, 1)
        XCTAssertEqual(r.opened.first?.cause, .router)
        XCTAssertEqual(r.opened.first?.start, t0.addingTimeInterval(6))
        XCTAssertEqual(d.current?.cause, .router)
    }

    func testGatewayUpInternetDownIsISPOutage() {
        var d = OutageDetector()
        let r = run(&d, from: 0, to: 12, gateway: true, internet: false)
        XCTAssertEqual(r.opened.first?.cause, .isp)
    }

    func testShortBlipIsNotAnOutage() {
        var d = OutageDetector()
        let r1 = run(&d, from: 0, to: 8, gateway: false, internet: false)
        let r2 = run(&d, from: 10, to: 20, gateway: true, internet: true)
        XCTAssertTrue(r1.opened.isEmpty && r2.opened.isEmpty && r2.closed.isEmpty)
    }

    func testWifiDisconnected() {
        var d = OutageDetector()
        let r = run(&d, from: 0, to: 12, gateway: false, internet: false, wifi: false)
        XCTAssertEqual(r.opened.first?.cause, .wifiDisconnected)
    }

    func testRecoveryClosesWithEnd() {
        var d = OutageDetector()
        run(&d, from: 0, to: 14, gateway: true, internet: false)
        let r = run(&d, from: 16, to: 16, gateway: true, internet: true)
        XCTAssertEqual(r.closed.count, 1)
        XCTAssertEqual(r.closed.first?.end, t0.addingTimeInterval(16))
        XCTAssertNil(d.current)
    }

    func testSleepGapResetsPendingFailure() {
        // Review Focus 1: a laptop lid close must not register an outage.
        var d = OutageDetector()
        run(&d, from: 0, to: 6, gateway: false, internet: false)          // pending since 0
        let r = run(&d, from: 3600, to: 3606, gateway: false, internet: false)  // woke 1 h later
        XCTAssertTrue(r.opened.isEmpty)
    }

    func testSleepGapClosesOpenOutageAtLastObservation() {
        var d = OutageDetector()
        run(&d, from: 0, to: 14, gateway: true, internet: false)
        let r = run(&d, from: 3600, to: 3600, gateway: true, internet: true)
        XCTAssertEqual(r.closed.first?.end, t0.addingTimeInterval(14))
    }

    func testUnpingableGatewayNeverBlamesRouter() {
        // Review Focus 3: routers that drop ICMP report gatewayOK == nil.
        var d = OutageDetector()
        let r = run(&d, from: 0, to: 12, gateway: nil, internet: false)
        XCTAssertEqual(r.opened.first?.cause, .unknown, "router unverified — can't claim the line is at fault either")
        var healthy = OutageDetector()
        XCTAssertTrue(run(&healthy, from: 0, to: 30, gateway: nil, internet: true).opened.isEmpty)
    }

    func testRecordCarriesNetworkId() {
        var d = OutageDetector()
        let r = run(&d, from: 0, to: 12, gateway: true, internet: false, network: "aa:bb")
        XCTAssertEqual(r.opened.first?.networkId, "aa:bb")
    }

    func testNoWifiButInternetWorkingIsNotAnOutage() {
        // Wired Macs have no Wi-Fi association; that alone isn't a failure.
        var d = OutageDetector()
        XCTAssertTrue(run(&d, from: 0, to: 30, gateway: true, internet: true, wifi: false).opened.isEmpty)
    }
}
