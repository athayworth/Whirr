import XCTest
@testable import WhirrCore

final class ConnectionReportCardTests: XCTestCase {
    private let link = WiFiLink(rssi: -60, noise: -90, channel: 149, band: "5 GHz", widthMHz: 80, txRateMbps: 600, phyMode: "802.11ax")

    private func hop(median: Double? = 5, spikes: Int = 0, loss: Double = 0, count: Int = 300) -> HopStats {
        HopStats(count: count, medianMs: median, p95Ms: nil, jitterMs: nil, lossPercent: loss, spikes: spikes)
    }

    private func result(down: Double? = 200, up: Double? = 30, idle: Double? = 20, loaded: Double? = 40,
                        gwIdle: Double? = 3, gwLoaded: Double? = 5, link: WiFiLink?? = nil,
                        neighbors: [NeighborCount] = [], nqFailed: Bool = false) -> ConnectionTestResult {
        ConnectionTestResult(
            at: Date(), networkId: "home",
            nq: nqFailed ? nil : NetworkQualityResult(downMbps: down, upMbps: up, idleLatencyMs: idle, loadedLatencyMs: loaded),
            gatewayIdle: hop(median: gwIdle), gatewayLoaded: hop(median: gwLoaded),
            link: link ?? self.link, neighbors: neighbors)
    }

    private func row(_ id: String, _ r: ConnectionTestResult, gateway: HopStats? = nil, internet: HopStats? = nil) -> ReportRow {
        ConnectionReportCard.rows(for: r, passiveGateway: gateway ?? hop(), passiveInternet: internet ?? hop())
            .first { $0.id == id }!
    }

    func testFourRowsInOrder() {
        let ids = ConnectionReportCard.rows(for: result(), passiveGateway: hop(), passiveInternet: hop()).map(\.id)
        XCTAssertEqual(ids, ["speed", "stability", "underLoad", "crowding"])
    }

    func testSpeedGrades() {
        XCTAssertEqual(row("speed", result(down: 50)).grade, .good)
        XCTAssertEqual(row("speed", result(down: 25)).grade, .ok)
        XCTAssertEqual(row("speed", result(down: 24)).grade, .poor)
        XCTAssertEqual(row("speed", result(down: nil)).grade, .unknown)
        XCTAssertEqual(row("speed", result(nqFailed: true)).grade, .unknown)
    }

    func testStabilityGradesAndBlamesTheRightHop() {
        XCTAssertEqual(row("stability", result()).grade, .good)
        let wifi = row("stability", result(), gateway: hop(spikes: 14))
        XCTAssertEqual(wifi.grade, .poor)
        XCTAssertTrue(wifi.explanation.contains("router"), wifi.explanation)
        let isp = row("stability", result(), gateway: hop(), internet: hop(spikes: 14))
        XCTAssertEqual(isp.grade, .poor)
        XCTAssertTrue(isp.fix?.contains("provider") ?? false, isp.fix ?? "")
        XCTAssertEqual(row("stability", result(), gateway: hop(spikes: 4)).grade, .ok)
        XCTAssertEqual(row("stability", result(), gateway: hop(count: 5), internet: hop(count: 5)).grade, .unknown)
    }

    func testUnderLoadGradesAndAttribution() {
        XCTAssertEqual(row("underLoad", result(idle: 20, loaded: 45)).grade, .good)
        XCTAssertEqual(row("underLoad", result(idle: 20, loaded: 110)).grade, .ok)
        let wifi = row("underLoad", result(idle: 21, loaded: 228, gwIdle: 3, gwLoaded: 150))
        XCTAssertEqual(wifi.grade, .poor)
        XCTAssertTrue(wifi.explanation.contains("Wi-Fi"), wifi.explanation)
        let line = row("underLoad", result(idle: 21, loaded: 228, gwIdle: 3, gwLoaded: 10))
        XCTAssertTrue(line.explanation.contains("internet line"), line.explanation)
        XCTAssertEqual(row("underLoad", result(nqFailed: true)).grade, .unknown)
    }

    func testCrowdingCountsOthersOnCurrentChannelAndSuggestsQuietNonDFS() {
        let neighbors = [NeighborCount(channel: 149, band: "5 GHz", count: 11),
                         NeighborCount(channel: 36, band: "5 GHz", count: 2),
                         NeighborCount(channel: 44, band: "5 GHz", count: 3),
                         NeighborCount(channel: 48, band: "5 GHz", count: 2)]
        let r = row("crowding", result(neighbors: neighbors))
        XCTAssertEqual(r.grade, .poor)
        XCTAssertTrue(r.explanation.contains("10"), r.explanation)   // 11 minus your own network
        XCTAssertTrue(r.fix?.contains("40") ?? false, r.fix ?? "")    // empty non-DFS channel
        XCTAssertTrue(r.fix?.contains("radar") ?? false, r.fix ?? "")
    }

    func testCrowdingGoodWhenAlone() {
        let r = row("crowding", result(neighbors: [NeighborCount(channel: 149, band: "5 GHz", count: 1)]))
        XCTAssertEqual(r.grade, .good)
        XCTAssertNil(r.fix)
    }

    func testCrowdingWiredNotApplicable() {
        let r = row("crowding", result(link: .some(nil)))
        XCTAssertEqual(r.grade, .unknown)
        XCTAssertTrue(r.explanation.contains("Wired"))
    }

    func testCrowding24GHzSuggestsOneSixEleven() {
        let l = WiFiLink(rssi: -50, noise: -90, channel: 6, band: "2.4 GHz", widthMHz: 20, txRateMbps: 100, phyMode: "802.11n")
        let n = [NeighborCount(channel: 6, band: "2.4 GHz", count: 8), NeighborCount(channel: 1, band: "2.4 GHz", count: 4)]
        XCTAssertTrue(row("crowding", result(link: .some(l), neighbors: n)).fix?.contains("11") ?? false)
    }
}
