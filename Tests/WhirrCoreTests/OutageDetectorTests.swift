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

    // MARK: Cause from the whole failing window, not one ping

    func testOneLostRouterPingDuringALineOutageIsStillTheLine() {
        var d = OutageDetector()
        run(&d, from: 0, to: 0, gateway: false, internet: false)   // first failing round: router ping lost
        let r = run(&d, from: 2, to: 12, gateway: true, internet: false)
        XCTAssertEqual(r.opened.first?.cause, .isp)
    }

    func testLastRoundAloneDoesNotDecideTheCause() {
        var d = OutageDetector()
        run(&d, from: 0, to: 8, gateway: true, internet: false)
        let r = run(&d, from: 10, to: 10, gateway: false, internet: false)
        XCTAssertEqual(r.opened.first?.cause, .isp)
    }

    func testEvenlySplitEvidenceIsUnknownRatherThanAGuess() {
        var d = OutageDetector()
        var t: TimeInterval = 0
        var opened: OutageRecord?
        while opened == nil && t <= 20 {
            let gatewayOK = Int(t / 2) % 2 == 0
            opened = d.observe(gatewayOK: gatewayOK, internetOK: false, wifiAssociated: true,
                               at: t0.addingTimeInterval(t), networkId: "home").opened
            t += 2
        }
        XCTAssertEqual(opened?.cause, .unknown)
    }
}

final class OutageRecordProvenanceTests: XCTestCase {
    func testNewOutagesUseTheCurrentCauseMethod() {
        var d = OutageDetector()
        var opened: OutageRecord?
        for i in 0...6 {
            opened = opened ?? d.observe(gatewayOK: true, internetOK: false, wifiAssociated: true,
                                         at: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 2), networkId: "home").opened
        }
        XCTAssertEqual(opened?.causeMethod, OutageRecord.currentCauseMethod)
        XCTAssertTrue(opened?.causeIsReliable ?? false)
    }

    func testOutagesSavedBeforeTheMethodExistedAreMarkedOlder() throws {
        let json = #"[{"id":"7E3F1C2A-1111-4222-8333-444455556666","start":"2026-10-15T06:16:39Z","end":"2026-10-15T06:17:09Z","cause":"router","networkId":"home"}]"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let old = try d.decode([OutageRecord].self, from: Data(json.utf8))
        XCTAssertFalse(old[0].causeIsReliable)
    }

    func testProviderSummaryOnlyCountsReliableCausesAndSaysSo() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let old = OutageRecord(start: t, end: t.addingTimeInterval(30), cause: .isp, networkId: "h", causeMethod: 1)
        let new = OutageRecord(start: t.addingTimeInterval(600), end: t.addingTimeInterval(660), cause: .isp, networkId: "h")
        let text = OutageReport.summary([old, new], now: t.addingTimeInterval(3600))
        XCTAssertTrue(text.contains("2"), text)
        XCTAssertTrue(text.contains("1 where the home router still answered"), text)
        XCTAssertTrue(text.contains("older version"), text)
    }
}
