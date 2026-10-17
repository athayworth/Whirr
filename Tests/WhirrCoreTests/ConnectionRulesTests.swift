import XCTest
@testable import WhirrCore

final class ConnectionRulesTests: XCTestCase {
    private let link = WiFiLink(rssi: -58, noise: -90, channel: 36, band: "5 GHz", widthMHz: 80, txRateMbps: 600, phyMode: "802.11ax")

    private func hop(spikes: Int = 0, loss: Double = 0, count: Int = 300) -> HopStats {
        HopStats(count: count, medianMs: 5, p95Ms: 10, jitterMs: 1, lossPercent: loss, spikes: spikes)
    }

    private func snap(gateway: HopStats? = nil, internet: HopStats? = nil, link: WiFiLink?? = nil,
                      isWired: Bool = false, pingable: Bool = true, outage: OutageRecord? = nil) -> ConnectionSnapshot {
        ConnectionSnapshot(link: link ?? self.link, isWired: isWired, gatewayPingable: pingable, networkId: "home",
                           gateway1m: .empty, internet1m: .empty,
                           gateway10m: gateway ?? hop(), internet10m: internet ?? hop(),
                           currentOutage: outage, paused: false)
    }

    private func evaluate(_ s: ConnectionSnapshot?) -> [Diagnosis] {
        let empty = SystemSnapshot.empty
        return RulesEngine().evaluate(snapshot: empty, processes: [], connection: s)
            .filter { $0.area == .connection }
    }

    private func find(_ title: String, _ s: ConnectionSnapshot) -> Diagnosis? {
        evaluate(s).first { $0.title == title }
    }

    func testHealthyConnectionHasNoFindings() {
        XCTAssertTrue(evaluate(snap()).isEmpty)
    }

    func testNoConnectionDataNoFindings() {
        XCTAssertTrue(evaluate(nil).isEmpty)
    }

    func testSpikyWifiWarningAndCritical() {
        XCTAssertNil(find(ConnectionTitles.spikyWiFi, snap(gateway: hop(spikes: 5))))
        let warn = find(ConnectionTitles.spikyWiFi, snap(gateway: hop(spikes: 6)))
        XCTAssertEqual(warn?.severity, .warning)
        XCTAssertEqual(warn?.area, .connection)
        // No evidence yet that the channel is the cause: offer the test
        // that finds out, not a channel change.
        XCTAssertEqual(warn?.action?.kind, .runConnectionTest)
        XCTAssertFalse(warn?.detail.contains("usual cause") ?? true)
        XCTAssertEqual(find(ConnectionTitles.spikyWiFi, snap(gateway: hop(loss: 2)))?.severity, .warning)
        XCTAssertEqual(find(ConnectionTitles.spikyWiFi, snap(gateway: hop(spikes: 20)))?.severity, .critical)
        XCTAssertEqual(find(ConnectionTitles.spikyWiFi, snap(gateway: hop(loss: 5)))?.severity, .critical)
    }

    func testSpikyWifiNeedsAMinuteOfData() {
        XCTAssertNil(find(ConnectionTitles.spikyWiFi, snap(gateway: hop(spikes: 20, count: 10))))
    }

    func testSpikyWifiNotReportedWhenWired() {
        XCTAssertNil(find(ConnectionTitles.spikyWiFi, snap(gateway: hop(spikes: 20), link: .some(nil), isWired: true)))
    }

    func testPastRouterOnlyWhenRouterHopIsClean() {
        let fires = find(ConnectionTitles.pastRouter, snap(gateway: hop(spikes: 1), internet: hop(spikes: 8)))
        XCTAssertEqual(fires?.severity, .warning)
        XCTAssertEqual(fires?.action?.kind, .showHowTo(.talkToISP))
        // Clean router + stalls beyond is also what your own uploads look
        // like, so the provider is one possibility, not the verdict.
        XCTAssertTrue(fires?.detail.contains("Possible causes") ?? false, fires?.detail ?? "")
        XCTAssertFalse(fires?.detail.contains("not your Wi-Fi") ?? true)
        XCTAssertNil(find(ConnectionTitles.pastRouter, snap(gateway: hop(spikes: 8), internet: hop(spikes: 8))))
        XCTAssertNil(find(ConnectionTitles.pastRouter, snap(gateway: hop(), internet: hop(), pingable: false)))
        XCTAssertEqual(find(ConnectionTitles.pastRouter, snap(internet: hop(loss: 6)))?.severity, .critical)
    }

    func testPastRouterUnknowableWhenRouterIgnoresPings() {
        XCTAssertNil(find(ConnectionTitles.pastRouter, snap(internet: hop(spikes: 30), pingable: false)))
    }

    func testWeakSignalFromRSSIOrSNRNeverCritical() {
        let weakRSSI = WiFiLink(rssi: -75, noise: -100, channel: 36, band: "5 GHz", widthMHz: 80, txRateMbps: 100, phyMode: "802.11ax")
        let lowSNR = WiFiLink(rssi: -65, noise: -80, channel: 36, band: "5 GHz", widthMHz: 80, txRateMbps: 100, phyMode: "802.11ax")
        XCTAssertEqual(find(ConnectionTitles.weakSignal, snap(link: .some(weakRSSI)))?.severity, .warning)
        XCTAssertEqual(find(ConnectionTitles.weakSignal, snap(link: .some(lowSNR)))?.action?.kind, .showHowTo(.improveSignal))
        XCTAssertNil(find(ConnectionTitles.weakSignal, snap()))
        XCTAssertNil(find(ConnectionTitles.weakSignal, snap(link: .some(nil), isWired: true)))
    }

    func testOutageIsCriticalWithCauseSpecificHelp() {
        let t = Date()
        let router = find(ConnectionTitles.outage, snap(outage: OutageRecord(start: t, cause: .router, networkId: "home")))
        XCTAssertEqual(router?.severity, .critical)
        XCTAssertEqual(router?.action?.kind, .showHowTo(.routerOutage))
        let isp = find(ConnectionTitles.outage, snap(outage: OutageRecord(start: t, cause: .isp, networkId: "home")))
        XCTAssertEqual(isp?.action?.kind, .showHowTo(.ispOutage))
    }

    func testOutageSuppressesSpikyAndPastRouter() {
        let s = snap(gateway: hop(spikes: 50), internet: hop(spikes: 50),
                     outage: OutageRecord(start: Date(), cause: .isp, networkId: "home"))
        XCTAssertEqual(evaluate(s).map(\.title), [ConnectionTitles.outage])
    }

    func testConfigDisablesRule() throws {
        let config = try JSONDecoder().decode(RulesConfig.self, from: Data(#"{"connection":{"enabled":false}}"#.utf8))
        let out = RulesEngine(config: config).evaluate(snapshot: .empty, processes: [], connection: snap(gateway: hop(spikes: 50)))
        XCTAssertTrue(out.filter { $0.area == .connection }.isEmpty)
    }

    func testUnknownOutageUsesNeutralCopy() {
        let d = find(ConnectionTitles.outage, snap(outage: OutageRecord(start: Date(), cause: .unknown, networkId: "home")))
        XCTAssertEqual(d?.action?.kind, .showHowTo(.connectionDown))
        XCTAssertFalse(d?.detail.contains("router is fine") ?? true)
    }

    func testWiFiDroppedOutageGetsItsOwnHelpNotRouterRestart() {
        let d = find(ConnectionTitles.outage, snap(outage: OutageRecord(start: Date(), cause: .wifiDisconnected, networkId: "home")))
        XCTAssertEqual(d?.action?.kind, .showHowTo(.wifiDropped))
    }

    func testWeakSignalWordingIsHedged() {
        let weak = WiFiLink(rssi: -75, noise: -100, channel: 36, band: "5 GHz", widthMHz: 80, txRateMbps: 100, phyMode: "802.11ax")
        let d = find(ConnectionTitles.weakSignal, snap(link: .some(weak)))
        XCTAssertTrue(d?.detail.contains("can slow down") ?? false, d?.detail ?? "")
    }

    func testSignalQualityAgreesWithTheWeakSignalRule() {
        func link(_ rssi: Int, _ noise: Int) -> WiFiLink {
            WiFiLink(rssi: rssi, noise: noise, channel: 36, band: "5 GHz", widthMHz: 80, txRateMbps: 100, phyMode: "802.11ax")
        }
        for l in [link(-71, -95), link(-72, -95), link(-73, -95), link(-65, -84), link(-65, -85), link(-55, -90)] {
            let ruleSaysWeak = find(ConnectionTitles.weakSignal, snap(link: .some(l))) != nil
            XCTAssertEqual(l.quality == .weak, ruleSaysWeak, "rssi \(l.rssi) snr \(l.snr)")
        }
        XCTAssertEqual(link(-55, -90).quality, .strong)
        XCTAssertEqual(link(-65, -90).quality, .ok)
    }

    func testOutageSummaryNamesEachCauseHonestly() {
        XCTAssertEqual(OutageCause.router.summary, "Router isn't responding.")
        XCTAssertEqual(OutageCause.isp.summary, "Internet is down beyond your router (the router answers).")
        XCTAssertEqual(OutageCause.wifiDisconnected.summary, "Wi-Fi disconnected.")
        XCTAssertEqual(OutageCause.unknown.summary, "Connection is down.")
    }
}
