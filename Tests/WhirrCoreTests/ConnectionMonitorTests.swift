import XCTest
@testable import WhirrCore

/// Scripted pinger: answers per host from a mutable table.
final class FakePinger: Pinging, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: Double?] = [:]
    private(set) var hostsPinged: [String] = []
    func set(_ host: String, _ rtt: Double?) { lock.withLock { table[host] = rtt } }
    func ping(_ host: String, timeout: TimeInterval) async -> Double? {
        lock.withLock {
            hostsPinged.append(host)
            return table[host] ?? nil
        }
    }
}

final class FakeWiFi: WiFiReading, @unchecked Sendable {
    static let defaultLink = WiFiLink(rssi: -60, noise: -90, channel: 36, band: "5 GHz", widthMHz: 80, txRateMbps: 600, phyMode: "802.11ax")
    private let lock = NSLock()
    private var _link: WiFiLink?
    init(link: WiFiLink? = FakeWiFi.defaultLink) { _link = link }
    var link: WiFiLink? {
        get { lock.withLock { _link } }
        set { lock.withLock { _link = newValue } }
    }
    func currentLink() -> WiFiLink? { link }
    func scanNeighbors() -> [NeighborNetwork]? { nil }
}

/// Gateway resolver whose answer tests can change mid-run.
final class GatewayBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: GatewayInfo?
    init(_ v: GatewayInfo?) { _value = v }
    var value: GatewayInfo? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

final class ConnectionMonitorTests: XCTestCase {
    private var dir: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let gw = GatewayInfo(ip: "192.168.1.1", mac: "aa:bb")

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("WhirrConnMon-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func monitor(_ pinger: FakePinger, wifi: FakeWiFi = FakeWiFi(), gateway: GatewayInfo? = nil) -> ConnectionMonitor {
        monitor(pinger, wifi: wifi, box: GatewayBox(gateway ?? gw))
    }

    private func monitor(_ pinger: FakePinger, wifi: FakeWiFi = FakeWiFi(), box: GatewayBox) -> ConnectionMonitor {
        ConnectionMonitor(pinger: pinger, wifi: wifi, store: ConnectionHistoryStore(directory: dir), gateway: { box.value })
    }

    private func rounds(_ m: ConnectionMonitor, _ n: Int, from: TimeInterval = 0) async {
        for i in 0..<n { await m.pingRound(at: t0.addingTimeInterval(from + Double(i) * 2)) }
    }

    func testSnapshotHasStatsAfterRounds() async {
        let p = FakePinger(); p.set("192.168.1.1", 3); p.set("1.1.1.1", 30)
        let m = monitor(p)
        await rounds(m, 6)
        let s = await m.snapshot(at: t0.addingTimeInterval(10))
        XCTAssertEqual(s.gateway1m.medianMs, 3)
        XCTAssertEqual(s.internet1m.medianMs, 30)
        XCTAssertEqual(s.networkId, "aa:bb")
        XCTAssertEqual(s.link?.channel, 36)
        XCTAssertTrue(s.gatewayPingable)
        XCTAssertFalse(s.isWired)
    }

    func testRouterThatNeverAnswersSwitchesToInternetOnlyAfterSixtySeconds() async {
        let p = FakePinger(); p.set("1.1.1.1", 30)  // gateway never answers
        let m = monitor(p)
        await rounds(m, 29)
        let early = await m.snapshot(at: t0.addingTimeInterval(58))
        XCTAssertTrue(early.gatewayPingable)
        await rounds(m, 2, from: 58)
        let later = await m.snapshot(at: t0.addingTimeInterval(62))
        XCTAssertFalse(later.gatewayPingable)
        XCTAssertNil(later.currentOutage, "an unpingable router must not look like an outage")
    }

    func testInternetHostFallsBackAfterThirtyFailuresWhileRouterAnswers() async {
        let p = FakePinger(); p.set("192.168.1.1", 3); p.set("8.8.8.8", 25)  // 1.1.1.1 blocked
        let m = monitor(p)
        await rounds(m, 31)
        p.set("192.168.1.1", 3)
        await rounds(m, 3, from: 62)
        XCTAssertEqual(p.hostsPinged.last { $0 != "192.168.1.1" }, "8.8.8.8")
        let s = await m.snapshot(at: t0.addingTimeInterval(66))
        XCTAssertEqual(s.internet1m.medianMs, 25)
    }

    func testPausedIgnoresRounds() async {
        let p = FakePinger(); p.set("192.168.1.1", 3); p.set("1.1.1.1", 30)
        let m = monitor(p)
        await m.setPaused(true)
        await rounds(m, 5)
        let s = await m.snapshot(at: t0.addingTimeInterval(10))
        XCTAssertEqual(s.gateway1m.count, 0)
        XCTAssertTrue(s.paused)
        XCTAssertTrue(p.hostsPinged.isEmpty)
    }

    func testWiredWhenNoWifiLinkButRouterAnswers() async {
        let p = FakePinger(); p.set("192.168.1.1", 1); p.set("1.1.1.1", 20)
        let m = monitor(p, wifi: FakeWiFi(link: nil))
        await rounds(m, 3)
        let s = await m.snapshot(at: t0.addingTimeInterval(4))
        XCTAssertTrue(s.isWired)
        XCTAssertNil(s.currentOutage)
    }

    func testOutageIsDetectedAndPersisted() async {
        let p = FakePinger(); p.set("192.168.1.1", 3)  // internet down
        let m = monitor(p)
        await rounds(m, 8)
        let s = await m.snapshot(at: t0.addingTimeInterval(14))
        XCTAssertEqual(s.currentOutage?.cause, .isp)
        XCTAssertEqual(ConnectionHistoryStore(directory: dir).outages().first?.cause, .isp)
    }

    func testMinuteAggregateWrittenOnMinuteRollover() async {
        let p = FakePinger(); p.set("192.168.1.1", 3); p.set("1.1.1.1", 30)
        let m = monitor(p)
        await rounds(m, 35)  // 70 s → crosses at least one minute boundary
        let aggs = ConnectionHistoryStore(directory: dir).aggregates(since: .distantPast)
        XCTAssertFalse(aggs.isEmpty)
        XCTAssertEqual(aggs.first?.networkId, "aa:bb")
        XCTAssertEqual(aggs.first?.channel, 36)
    }

    // MARK: Review fixes

    func testWifiDropOnWifiMacIsWifiDisconnectedNotWired() {
        let p = FakePinger(); p.set("192.168.1.1", 3); p.set("1.1.1.1", 30)
        let wifi = FakeWiFi()
        let m = monitor(p, wifi: wifi)
        let exp = expectation(description: "done")
        Task {
            await rounds(m, 5)
            wifi.link = nil
            p.set("192.168.1.1", nil); p.set("1.1.1.1", nil)
            await rounds(m, 8, from: 10)
            let s = await m.snapshot(at: t0.addingTimeInterval(26))
            XCTAssertFalse(s.isWired)
            XCTAssertEqual(s.currentOutage?.cause, .wifiDisconnected)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testGatewayChangeIsPickedUpOnTheNextRound() async {
        let p = FakePinger(); p.set("192.168.1.1", 3); p.set("172.20.10.1", 8); p.set("1.1.1.1", 30)
        let box = GatewayBox(gw)
        let m = monitor(p, box: box)
        await rounds(m, 5)
        box.value = GatewayInfo(ip: "172.20.10.1", mac: "cc:dd")
        await m.pingRound(at: t0.addingTimeInterval(10))
        let s = await m.snapshot(at: t0.addingTimeInterval(10))
        XCTAssertEqual(s.networkId, "cc:dd")
        XCTAssertEqual(p.hostsPinged.suffix(2).sorted(), ["1.1.1.1", "172.20.10.1"])
        XCTAssertEqual(s.gateway1m.count, 1, "home samples must not mix into the hotspot's")
    }

    func testMissingARPEntryKeepsLastMACForSameRouter() async {
        let p = FakePinger(); p.set("192.168.1.1", 3); p.set("1.1.1.1", 30)
        let box = GatewayBox(gw)
        let m = monitor(p, box: box)
        await rounds(m, 5)
        box.value = GatewayInfo(ip: "192.168.1.1", mac: nil)
        await rounds(m, 3, from: 10)
        let s = await m.snapshot(at: t0.addingTimeInterval(14))
        XCTAssertEqual(s.networkId, "aa:bb")
        XCTAssertEqual(s.gateway1m.count, 8)
    }

    func testRouterRebootLeavesNoSpikesAfterRecovery() async {
        let p = FakePinger(); p.set("192.168.1.1", 3); p.set("1.1.1.1", 30)
        let m = monitor(p)
        await rounds(m, 5)
        p.set("192.168.1.1", nil); p.set("1.1.1.1", nil)
        await rounds(m, 30, from: 10)           // 60 s reboot → outage
        p.set("192.168.1.1", 3); p.set("1.1.1.1", 30)
        await rounds(m, 10, from: 70)
        let s = await m.snapshot(at: t0.addingTimeInterval(88))
        XCTAssertNil(s.currentOutage)
        XCTAssertEqual(s.gateway10m.spikes, 0)
        XCTAssertEqual(s.internet10m.lossPercent, 0)
    }

    func testShortBlipStillCountsAsSpikes() async {
        let p = FakePinger(); p.set("192.168.1.1", 3); p.set("1.1.1.1", 30)
        let m = monitor(p)
        await rounds(m, 5)
        p.set("192.168.1.1", nil); p.set("1.1.1.1", nil)
        await rounds(m, 3, from: 10)            // 6 s — not an outage
        p.set("192.168.1.1", 3); p.set("1.1.1.1", 30)
        await rounds(m, 5, from: 16)
        let s = await m.snapshot(at: t0.addingTimeInterval(24))
        XCTAssertEqual(s.gateway10m.spikes, 3)
    }

    func testUnconfirmedRouterPlusInternetDownIsNotBlamedOnRouter() async {
        let p = FakePinger()                     // nothing answers from the start
        let m = monitor(p)
        await rounds(m, 8)
        let s = await m.snapshot(at: t0.addingTimeInterval(14))
        XCTAssertEqual(s.currentOutage?.cause, .unknown)
    }
}
