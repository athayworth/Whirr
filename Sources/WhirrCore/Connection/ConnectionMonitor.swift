import Foundation

/// Everything the rules and UI need to know about the connection now.
public struct ConnectionSnapshot: Sendable, Equatable {
    public let link: WiFiLink?
    /// Router answers but there's no Wi-Fi association — Ethernet.
    public let isWired: Bool
    /// False when the router has never answered pings on this network
    /// (some block ICMP). Then only the internet hop is judged.
    public let gatewayPingable: Bool
    public let networkId: String?
    public let gateway1m: HopStats
    public let internet1m: HopStats
    public let gateway10m: HopStats
    public let internet10m: HopStats
    public let currentOutage: OutageRecord?
    public let paused: Bool

    public init(link: WiFiLink?, isWired: Bool, gatewayPingable: Bool, networkId: String?,
                gateway1m: HopStats, internet1m: HopStats, gateway10m: HopStats, internet10m: HopStats,
                currentOutage: OutageRecord?, paused: Bool) {
        self.link = link
        self.isWired = isWired
        self.gatewayPingable = gatewayPingable
        self.networkId = networkId
        self.gateway1m = gateway1m
        self.internet1m = internet1m
        self.gateway10m = gateway10m
        self.internet10m = internet10m
        self.currentOutage = currentOutage
        self.paused = paused
    }

    public static let empty = ConnectionSnapshot(
        link: nil, isWired: false, gatewayPingable: true, networkId: nil,
        gateway1m: .empty, internet1m: .empty, gateway10m: .empty, internet10m: .empty,
        currentOutage: nil, paused: false
    )
}

/// The passive connection watcher. Every 2 s it pings the router and an
/// internet host, reads the Wi-Fi link, updates rolling stats, detects
/// outages and writes one aggregate per minute. It never scans for
/// networks (scans take the radio off-channel and cause the very spikes
/// it measures).
public actor ConnectionMonitor {
    public static let interval: TimeInterval = 2
    static let pingTimeout: TimeInterval = 1
    /// Rounds with no router reply (while the internet answers) before we
    /// conclude the router ignores pings: 30 × 2 s = 60 s.
    static let unpingableAfterRounds = 30
    static let fallbackAfterFailures = 30
    static let primaryInternetHost = "1.1.1.1"
    static let fallbackInternetHost = "8.8.8.8"

    private let pinger: Pinging
    private let wifi: WiFiReading
    private let store: ConnectionHistoryStore
    private let resolveGateway: @Sendable () -> GatewayInfo?

    private var stats = ConnectionStats()
    private var outages = OutageDetector()
    private var gateway: GatewayInfo?
    /// Pings taken while failing but before an outage is confirmed. If
    /// the failure becomes an outage they're dropped — otherwise a router
    /// reboot's timeouts would read as "spiky Wi-Fi" for 10 minutes after
    /// and skew the channel history. If it recovers, they're kept (a
    /// short blip is a real stall).
    private var pendingSamples: [PingSample] = []
    private var lastLink: WiFiLink?
    private var paused = false
    private var loop: Task<Void, Never>?

    // Per-network state, reset when the router changes.
    private var networkId: String?
    private var roundsOnNetwork = 0
    private var gatewayEverAnswered = false
    /// A Wi-Fi link was seen on this network — so a missing link later
    /// means Wi-Fi dropped, not that the Mac is wired.
    private var wifiSeenOnNetwork = false
    private var internetEverAnswered = false
    private var gatewayPingable = true
    private var internetHost = ConnectionMonitor.primaryInternetHost
    private var primaryHostFailures = 0
    private var currentMinute: Date?
    private var lastRoundAt: Date?
    /// Day of the last retention purge — history is trimmed daily while
    /// running, not only at launch.
    private var lastPurgeDay: Date?

    public init(
        pinger: Pinging = ICMPPinger(),
        wifi: WiFiReading = CoreWLANReader(),
        store: ConnectionHistoryStore = ConnectionHistoryStore(),
        gateway: @escaping @Sendable () -> GatewayInfo? = { GatewayResolver.current() }
    ) {
        self.pinger = pinger
        self.wifi = wifi
        self.store = store
        self.resolveGateway = gateway
    }

    public func start() {
        guard loop == nil else { return }
        store.purge(olderThan: Date().addingTimeInterval(-ConnectionHistoryStore.retention))
        // An outage open when the app last quit can't be "ongoing" now.
        // The last minute written is the last moment we know about.
        let lastKnown = store.aggregates(since: Date().addingTimeInterval(-86_400)).last?.minute
        store.closeDanglingOutages(at: lastKnown.map { $0.addingTimeInterval(60) } ?? Date())
        loop = Task { [weak self] in
            var next = ContinuousClock.now
            while !Task.isCancelled {
                next += .seconds(ConnectionMonitor.interval)
                if next < .now { next = .now + .seconds(ConnectionMonitor.interval) }
                do { try await Task.sleep(until: next, clock: .continuous) } catch { return }
                await self?.pingRound(at: Date())
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    public func setPaused(_ value: Bool) {
        paused = value
    }

    public func snapshot(at now: Date = Date()) -> ConnectionSnapshot {
        ConnectionSnapshot(
            link: lastLink,
            isWired: isWired,
            gatewayPingable: gatewayPingable,
            networkId: networkId,
            gateway1m: stats.stats(hop: .gateway, window: 60, now: now),
            internet1m: stats.stats(hop: .internet, window: 60, now: now),
            gateway10m: stats.stats(hop: .gateway, window: 600, now: now),
            internet10m: stats.stats(hop: .internet, window: 600, now: now),
            currentOutage: outages.current,
            paused: paused
        )
    }

    private var isWired: Bool { lastLink == nil && gatewayEverAnswered && !wifiSeenOnNetwork }

    /// One 2-second iteration. Exposed for tests, which drive time.
    public func pingRound(at now: Date) async {
        guard !paused else { return }
        purgeIfNewDay(now)
        refreshGateway()
        // The link as of the previous round belongs to the minute that
        // round closed — recorded with that minute, not with this one.
        let linkDuringLastRound = lastLink
        lastLink = wifi.currentLink()

        let gatewayIP = gateway?.ip
        let host = internetHost
        let otherHost = host == Self.primaryInternetHost ? Self.fallbackInternetHost : Self.primaryInternetHost
        // Two independent public hosts: the internet only counts as down
        // when both fail, so a network that blocks one never logs an outage.
        async let gatewayRTT: Double? = gatewayIP == nil ? nil : pinger.ping(gatewayIP!, timeout: Self.pingTimeout)
        async let internetRTT: Double? = pinger.ping(host, timeout: Self.pingTimeout)
        async let otherRTT: Double? = pinger.ping(otherHost, timeout: Self.pingTimeout)
        let (g, hostRTT, other) = await (gatewayRTT, internetRTT, otherRTT)
        // Stats follow one host so typical delay stays comparable; a lost
        // reply from it while the other answered isn't a lost internet.
        let i = hostRTT ?? other

        let id = gateway?.networkId ?? networkId ?? "unknown"
        if id != networkId { resetNetworkState(id) }
        roundsOnNetwork += 1
        if lastLink != nil { wifiSeenOnNetwork = true }
        if g != nil { gatewayEverAnswered = true }
        if i != nil { internetEverAnswered = true }
        if !gatewayEverAnswered && internetEverAnswered && roundsOnNetwork >= Self.unpingableAfterRounds {
            gatewayPingable = false
        }
        trackInternetHostFallback(primaryOK: hostRTT != nil, otherOK: other != nil)

        let result = outages.observe(
            gatewayOK: gatewayPingable && gatewayEverAnswered ? (g != nil) : nil,
            internetOK: i != nil,
            wifiAssociated: lastLink != nil || isWired,
            at: now,
            networkId: id
        )
        if let closed = result.closed { store.updateOutage(closed) }
        if let opened = result.opened { store.appendOutage(opened) }

        var samples = [PingSample(at: now, hop: .internet, rttMs: i)]
        if gatewayPingable { samples.insert(PingSample(at: now, hop: .gateway, rttMs: g), at: 0) }
        if outages.current != nil {
            pendingSamples.removeAll()
        } else if outages.isPending {
            pendingSamples += samples
        } else {
            for sample in pendingSamples + samples { stats.record(sample, networkId: id) }
            pendingSamples.removeAll()
        }

        writeMinuteAggregateIfDue(now: now, networkId: id, link: linkDuringLastRound)
        lastRoundAt = now
    }

    private func purgeIfNewDay(_ now: Date) {
        let day = Calendar.current.startOfDay(for: now)
        guard day != lastPurgeDay else { return }
        if lastPurgeDay != nil { store.purge(olderThan: now.addingTimeInterval(-ConnectionHistoryStore.retention)) }
        lastPurgeDay = day
    }

    /// Re-resolved every round (one SCDynamicStore read + one ARP sysctl)
    /// so a network switch is picked up within 2 s, before any of the new
    /// network's pings are filed under the old one.
    private func refreshGateway() {
        guard let fresh = resolveGateway() else {
            gateway = nil
            return
        }
        // A cold ARP entry briefly hides the router's MAC. Same IP as
        // before means same router — keep its identity instead of
        // flapping to the IP and splitting history.
        if fresh.mac == nil, let previous = gateway, previous.ip == fresh.ip {
            gateway = previous
        } else {
            gateway = fresh
        }
    }

    private func resetNetworkState(_ id: String) {
        networkId = id
        roundsOnNetwork = 0
        gatewayEverAnswered = false
        wifiSeenOnNetwork = false
        pendingSamples.removeAll()
        internetEverAnswered = false
        gatewayPingable = true
        internetHost = Self.primaryInternetHost
        primaryHostFailures = 0
        currentMinute = nil
    }

    /// Some networks block 1.1.1.1 specifically. If it keeps failing
    /// while 8.8.8.8 answers, base the stats on 8.8.8.8 instead.
    private func trackInternetHostFallback(primaryOK: Bool, otherOK: Bool) {
        guard internetHost == Self.primaryInternetHost else { return }
        if !primaryOK && otherOK {
            primaryHostFailures += 1
            if primaryHostFailures >= Self.fallbackAfterFailures {
                internetHost = Self.fallbackInternetHost
            }
        } else if primaryOK {
            primaryHostFailures = 0
        }
    }

    private func writeMinuteAggregateIfDue(now: Date, networkId: String, link: WiFiLink?) {
        let minute = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
        defer { currentMinute = minute }
        guard let previous = currentMinute, previous != minute, let lastRoundAt else { return }
        store.append(MinuteAggregate(
            minute: previous,
            networkId: networkId,
            gateway: stats.stats(hop: .gateway, window: 60, now: lastRoundAt),
            internet: stats.stats(hop: .internet, window: 60, now: lastRoundAt),
            channel: link?.channel,
            band: link?.band,
            rssi: link?.rssi,
            noise: link?.noise,
            widthMHz: link?.widthMHz
        ))
    }
}
