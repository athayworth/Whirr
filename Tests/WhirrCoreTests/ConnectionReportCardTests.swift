import XCTest
@testable import WhirrCore

final class ConnectionReportCardTests: XCTestCase {
    private let link = WiFiLink(rssi: -60, noise: -90, channel: 157, band: "5 GHz", widthMHz: 80, txRateMbps: 600, phyMode: "802.11ax")

    private func hop(median: Double? = 5, spikes: Int = 0, loss: Double = 0, count: Int = 300) -> HopStats {
        HopStats(count: count, medianMs: median, p95Ms: nil, jitterMs: nil, lossPercent: loss, spikes: spikes)
    }

    private func before(gateway: HopStats? = nil, internet: HopStats? = nil, pingable: Bool = true,
                        wired: Bool = false) -> PassiveBefore {
        PassiveBefore(gateway: gateway ?? hop(), internet: internet ?? hop(), gatewayPingable: pingable, isWired: wired)
    }

    private func net(_ channel: Int, _ width: Int = 80, rssi: Int = -60, band: String = "5 GHz") -> NeighborNetwork {
        NeighborNetwork(channel: channel, band: band, widthMHz: width, rssi: rssi)
    }

    private func result(down: Double? = 200, up: Double? = 30, idle: Double? = 20, loaded: Double? = 40,
                        gwIdle: Double? = 3, gwLoaded: Double? = 5, gwCount: Int = 100, link: WiFiLink?? = nil,
                        neighbors: [NeighborNetwork]?? = nil, before: PassiveBefore?? = nil,
                        nqFailed: Bool = false) -> ConnectionTestResult {
        ConnectionTestResult(
            at: Date(), networkId: "home",
            nq: nqFailed ? nil : NetworkQualityResult(downMbps: down, upMbps: up, idleLatencyMs: idle, loadedLatencyMs: loaded),
            gatewayIdle: hop(median: gwIdle, count: gwCount), gatewayLoaded: hop(median: gwLoaded, count: gwCount),
            link: link ?? self.link, neighbors: neighbors ?? [net(157)], before: before ?? self.before())
    }

    private func row(_ id: String, _ r: ConnectionTestResult) -> ReportRow {
        ConnectionReportCard.rows(for: r).first { $0.id == id }!
    }

    func testFourRowsInOrder() {
        XCTAssertEqual(ConnectionReportCard.rows(for: result()).map(\.id), ["speed", "stability", "underLoad", "crowding"])
    }

    // MARK: Speed

    func testSpeedGrades() {
        XCTAssertEqual(row("speed", result(down: 50)).grade, .good)
        XCTAssertEqual(row("speed", result(down: 25)).grade, .ok)
        XCTAssertEqual(row("speed", result(down: 24)).grade, .poor)
        XCTAssertEqual(row("speed", result(down: nil)).grade, .unknown)
        XCTAssertEqual(row("speed", result(nqFailed: true)).grade, .unknown)
    }

    // MARK: Stability

    func testStabilityUsesTheTenMinutesBeforeTheTestNotNow() {
        let r = row("stability", result(before: before(gateway: hop(spikes: 14))))
        XCTAssertEqual(r.grade, .poor)
        XCTAssertTrue(r.explanation.contains("before the test"), r.explanation)
    }

    func testStabilityUnknownForTestsWithoutBeforeData() {
        let r = row("stability", result(before: .some(nil)))
        XCTAssertEqual(r.grade, .unknown)
        XCTAssertTrue(r.explanation.contains("wasn't recorded"), r.explanation)
    }

    func testStabilityGradesAndBlamesTheRightHop() {
        XCTAssertEqual(row("stability", result()).grade, .good)
        let wifi = row("stability", result(before: before(gateway: hop(spikes: 14))))
        XCTAssertEqual(wifi.grade, .poor)
        XCTAssertTrue(wifi.explanation.contains("router"), wifi.explanation)
        let isp = row("stability", result(before: before(internet: hop(spikes: 14))))
        XCTAssertEqual(isp.grade, .poor)
        XCTAssertTrue(isp.fix?.contains("provider") ?? false, isp.fix ?? "")
        XCTAssertEqual(row("stability", result(before: before(gateway: hop(spikes: 4)))).grade, .ok)
        XCTAssertEqual(row("stability", result(before: before(gateway: hop(count: 5), internet: hop(count: 5)))).grade, .unknown)
    }

    func testWiFiStallFixDoesNotPrescribeAChannelChange() {
        let r = row("stability", result(before: before(gateway: hop(spikes: 14))))
        XCTAssertFalse(r.fix?.contains("channel to") ?? false, r.fix ?? "")
        XCTAssertTrue(r.fix?.contains("Common causes") ?? false, r.fix ?? "")
    }

    func testWiFiStallFixNamesWeakSignalWhenTheSignalWasWeak() {
        let weak = WiFiLink(rssi: -78, noise: -90, channel: 157, band: "5 GHz", widthMHz: 80, txRateMbps: 100, phyMode: "802.11ax")
        let r = row("stability", result(link: .some(weak), before: before(gateway: hop(spikes: 14))))
        XCTAssertTrue(r.fix?.contains("weak") ?? false, r.fix ?? "")
    }

    func testStabilityDoesNotClaimWifiIsFineWithoutRouterData() {
        let r = row("stability", result(before: before(gateway: .empty, internet: hop(spikes: 14), pingable: false)))
        XCTAssertEqual(r.grade, .poor)
        XCTAssertFalse(r.explanation.contains("steady"), r.explanation)
        XCTAssertFalse(r.fix?.contains("provider's side") ?? false)
    }

    func testStabilityOnWiredMacDoesNotMentionWifi() {
        let r = row("stability", result(link: .some(nil), before: before(gateway: hop(spikes: 14), wired: true)))
        XCTAssertFalse(r.explanation.contains("Wi-Fi"), r.explanation)
        XCTAssertFalse(r.fix?.contains("Wi-Fi") ?? false, r.fix ?? "")
    }

    // MARK: Under load

    func testUnderLoadGradesAndAttribution() {
        XCTAssertEqual(row("underLoad", result(idle: 20, loaded: 45)).grade, .good)
        XCTAssertEqual(row("underLoad", result(idle: 20, loaded: 110)).grade, .ok)
        let wifi = row("underLoad", result(idle: 21, loaded: 228, gwIdle: 3, gwLoaded: 150))
        XCTAssertEqual(wifi.grade, .poor)
        XCTAssertTrue(wifi.explanation.contains("your Wi-Fi"), wifi.explanation)
        let line = row("underLoad", result(idle: 21, loaded: 228, gwIdle: 3, gwLoaded: 10))
        XCTAssertTrue(line.explanation.contains("internet line"), line.explanation)
        XCTAssertEqual(row("underLoad", result(nqFailed: true)).grade, .unknown)
    }

    func testUnderLoadMakesNoAttributionWithoutRouterSamples() {
        for count in [0, 5] {
            let u = row("underLoad", result(idle: 21, loaded: 228, gwIdle: count == 0 ? nil : 3,
                                            gwLoaded: count == 0 ? nil : 10, gwCount: count))
            XCTAssertEqual(u.grade, .poor)
            XCTAssertFalse(u.explanation.contains("internet line"), u.explanation)
            XCTAssertFalse(u.explanation.contains("your Wi-Fi"), u.explanation)
        }
    }

    // MARK: Crowding

    func testCrowdingCountsWidthOverlapNotExactChannelNumbers() {
        // The real scan: router on 157 at 80 MHz shares 149–161 with
        // networks on 149, even though none of them are "on 157".
        let n = [net(157), net(157, rssi: -43), net(149), net(149), net(149), net(149, rssi: -78),
                 net(36), net(44), net(48)]
        let r = row("crowding", result(neighbors: n))
        XCTAssertTrue(r.explanation.contains("6 Wi-Fi networks"), r.explanation)
        XCTAssertTrue(r.explanation.contains("channels 149–161"), r.explanation)
        XCTAssertTrue(r.explanation.contains("including yours"), r.explanation)
        XCTAssertEqual(r.grade, .poor)
    }

    func testWeakNeighborsAreHeardButDoNotCountAsCompeting() {
        let n = [net(157), net(149, rssi: -85), net(149, rssi: -88), net(149, rssi: -90)]
        let r = row("crowding", result(neighbors: n))
        XCTAssertTrue(r.explanation.contains("4 Wi-Fi networks"), r.explanation)
        XCTAssertEqual(r.grade, .good)
    }

    func testCrowdingFixOnlyWhenWiFiWasActuallyTroubled() {
        let busy = [net(157), net(149), net(149), net(149), net(149), net(149), net(36)]
        let calm = row("crowding", result(neighbors: busy))
        XCTAssertEqual(calm.grade, .poor)
        XCTAssertNil(calm.fix, calm.fix ?? "")
        XCTAssertTrue(calm.explanation.contains("steady"), calm.explanation)

        let stalled = row("crowding", result(neighbors: busy, before: before(gateway: hop(spikes: 14))))
        XCTAssertNotNil(stalled.fix)

        let bloated = row("crowding", result(idle: 21, loaded: 228, gwIdle: 3, gwLoaded: 150, neighbors: busy))
        XCTAssertNotNil(bloated.fix)
    }

    func testCrowdingFixSuggestsQuietestStretchesWithCounts() {
        let busy = [net(157), net(149), net(149), net(149), net(149), net(149), net(36), net(44)]
        let r = row("crowding", result(neighbors: busy, before: before(gateway: hop(spikes: 14))))
        let fix = r.fix ?? ""
        XCTAssertTrue(fix.contains("if your router lets you choose"), fix)
        XCTAssertTrue(fix.contains("channel 52") || fix.contains("channel 100"), fix)
        XCTAssertFalse(fix.contains("channel 36"), fix)     // 36–48 had two loud networks
        XCTAssertTrue(fix.contains("radar"), fix)          // 52/100 are radar-shared
    }

    func testCrowdingSaysChangingWontHelpWhenEverywhereIsBusy() {
        var n = [net(157)]
        for ch in [36, 52, 100, 116, 132, 149] { n += Array(repeating: net(ch), count: 6) }
        let r = row("crowding", result(neighbors: n, before: before(gateway: hop(spikes: 14))))
        XCTAssertTrue(r.fix?.contains("unlikely to help") ?? false, r.fix ?? "")
    }

    func testCrowdingUnknownWhenScanMissingOrFromOldVersion() {
        let r = row("crowding", result(neighbors: .some(nil)))
        XCTAssertEqual(r.grade, .unknown)
        XCTAssertFalse(r.explanation.contains("0"), r.explanation)
    }

    func testCrowdingUnknownWhenOwnNetworkWasNotEvenHeard() {
        let r = row("crowding", result(neighbors: [net(36)]))
        XCTAssertEqual(r.grade, .unknown)
        XCTAssertTrue(r.explanation.contains("incomplete"), r.explanation)
    }

    func testCrowdingWiredVersusWiFiOff() {
        let wired = row("crowding", result(link: .some(nil), before: before(wired: true)))
        XCTAssertEqual(wired.grade, .unknown)
        XCTAssertTrue(wired.explanation.contains("Wired"), wired.explanation)
        let off = row("crowding", result(link: .some(nil), before: before(wired: false)))
        XCTAssertFalse(off.explanation.contains("Wired"), off.explanation)
    }

    func testCrowding24GHzSuggestsOneSixEleven() {
        let l = WiFiLink(rssi: -50, noise: -90, channel: 6, band: "2.4 GHz", widthMHz: 20, txRateMbps: 100, phyMode: "802.11n")
        var n = Array(repeating: net(6, 20, band: "2.4 GHz"), count: 8)
        n += Array(repeating: net(1, 20, band: "2.4 GHz"), count: 4)
        let r = row("crowding", result(link: .some(l), neighbors: n, before: before(gateway: hop(spikes: 14))))
        XCTAssertTrue(r.fix?.contains("channel 11") ?? false, r.fix ?? "")
        XCTAssertFalse(r.fix?.contains("radar") ?? true)
    }

    // MARK: Decoding

    func testOldSavedResultsDecodeWithoutInventingData() throws {
        let legacy = """
        {"id":"7E3F1C2A-1111-4222-8333-444455556666","at":"2026-10-14T20:00:00Z","networkId":"home",
         "gatewayIdle":{"count":0,"lossPercent":0,"spikes":0},"gatewayLoaded":{"count":0,"lossPercent":0,"spikes":0},
         "neighbors":[{"channel":36,"band":"5 GHz","count":3}]}
        """
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let r = try d.decode(ConnectionTestResult.self, from: Data(legacy.utf8))
        XCTAssertNil(r.neighbors)
        XCTAssertNil(r.before)
    }

    // MARK: Review fixes

    func testCrowdingNeverClaimsSteadyWithoutRouterEvidence() {
        let busy = [net(157), net(149), net(149), net(149), net(149), net(149)]
        for b in [before(gateway: .empty, pingable: false), before(gateway: hop(count: 5))] {
            let r = row("crowding", result(neighbors: busy, before: b))
            XCTAssertFalse(r.explanation.contains("steady"), r.explanation)
            XCTAssertTrue(r.explanation.contains("couldn't check"), r.explanation)
        }
        let old = row("crowding", result(neighbors: busy, before: .some(nil)))
        XCTAssertFalse(old.explanation.contains("steady"), old.explanation)
    }

    func testNoChannelSuggestionWhenThereIsNothingToCompare() {
        let six = WiFiLink(rssi: -55, noise: -90, channel: 37, band: "6 GHz", widthMHz: 160, txRateMbps: 1200, phyMode: "802.11ax")
        let n = Array(repeating: net(37, 160, band: "6 GHz"), count: 7)
        let r = row("crowding", result(link: .some(six), neighbors: n, before: before(gateway: hop(spikes: 14))))
        XCTAssertFalse(r.fix?.contains("about as busy") ?? false, r.fix ?? "")
        XCTAssertTrue(r.fix?.contains("can't compare") ?? false, r.fix ?? "")
    }

    func testStabilityReportsInternetStallsEvenWhenTheRouterHopHadAFew() {
        let r = row("stability", result(before: before(gateway: hop(spikes: 4), internet: hop(spikes: 30))))
        XCTAssertEqual(r.grade, .poor)
        XCTAssertTrue(r.explanation.contains("30"), r.explanation)
    }

    func testRouterHopStallsAreNotAttributedToWiFiAlone() {
        let r = row("stability", result(before: before(gateway: hop(spikes: 14))))
        XCTAssertFalse(r.explanation.contains("Wi-Fi link"), r.explanation)
        XCTAssertTrue(r.explanation.contains("between your Mac and the router"), r.explanation)
    }

    func testCrowdingWordingIsMeasuredAtTheMacAndHedgesRadar() {
        let busy = [net(157), net(149), net(149), net(149), net(149), net(149), net(36)]
        let r = row("crowding", result(neighbors: busy, before: before(gateway: hop(spikes: 14))))
        XCTAssertTrue(r.explanation.contains("at your Mac"), r.explanation)
        XCTAssertFalse(r.explanation.contains("make your router wait"), r.explanation)
        XCTAssertTrue(r.fix?.contains("can drop") ?? false, r.fix ?? "")
    }
}
