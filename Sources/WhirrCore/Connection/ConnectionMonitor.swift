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
    static let gatewayRefreshRounds = 30
    static let primaryInternetHost = "1.1.1.1"
    static let fallbackInternetHost = "8.8.8.8"

    private let pinger: Pinging
    private let wifi: WiFiReading
    private let store: ConnectionHistoryStore
    private let resolveGateway: @Sendable () -> GatewayInfo?

    private var stats = ConnectionStats()
    private var outages = OutageDetector()
    private var gateway: GatewayInfo?
    private var roundsSinceGatewayRefresh = 0
    private var lastLink: WiFiLink?
    private var paused = false
    private var loop: Task<Void, Never>?

    // Per-network state, reset when the router changes.
    private var networkId: String?
    private var roundsOnNetwork = 0
    private var gatewayEverAnswered = false
    private var internetEverAnswered = false
    private var gatewayPingable = true
    private var internetHost = ConnectionMonitor.primaryInternetHost
    private var primaryHostFailures = 0
    private var currentMinute: Date?
    private var lastRoundAt: Date?

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

    private var isWired: Bool { lastLink == nil && gatewayEverAnswered }

    /// One 2-second iteration. Exposed for tests, which drive time.
    public func pingRound(at now: Date) async {
        guard !paused else { return }
        refreshGatewayIfDue()
        lastLink = wifi.currentLink()

        let gatewayIP = gateway?.ip
        let host = internetHost
        async let gatewayRTT: Double? = gatewayIP == nil ? nil : pinger.ping(gatewayIP!, timeout: Self.pingTimeout)
        async let internetRTT: Double? = pinger.ping(host, timeout: Self.pingTimeout)
        let (g, i) = await (gatewayRTT, internetRTT)

        let id = gateway?.networkId ?? networkId ?? "unknown"
        if id != networkId { resetNetworkState(id) }
        roundsOnNetwork += 1
        if g != nil { gatewayEverAnswered = true }
        if i != nil { internetEverAnswered = true }
        if !gatewayEverAnswered && internetEverAnswered && roundsOnNetwork >= Self.unpingableAfterRounds {
            gatewayPingable = false
        }
        trackInternetHostFallback(gatewayOK: g != nil, internetOK: i != nil)

        if gatewayPingable {
            stats.record(PingSample(at: now, hop: .gateway, rttMs: g), networkId: id)
        }
        stats.record(PingSample(at: now, hop: .internet, rttMs: i), networkId: id)

        let result = outages.observe(
            gatewayOK: gatewayPingable ? (g != nil) : nil,
            internetOK: i != nil,
            wifiAssociated: lastLink != nil || isWired,
            at: now,
            networkId: id
        )
        if let closed = result.closed { store.updateOutage(closed) }
        if let opened = result.opened { store.appendOutage(opened) }

        writeMinuteAggregateIfDue(now: now, networkId: id)
        lastRoundAt = now
    }

    private func refreshGatewayIfDue() {
        if gateway == nil || roundsSinceGatewayRefresh >= Self.gatewayRefreshRounds {
            gateway = resolveGateway()
            roundsSinceGatewayRefresh = 0
        }
        roundsSinceGatewayRefresh += 1
    }

    private func resetNetworkState(_ id: String) {
        networkId = id
        roundsOnNetwork = 0
        gatewayEverAnswered = false
        internetEverAnswered = false
        gatewayPingable = true
        internetHost = Self.primaryInternetHost
        primaryHostFailures = 0
        currentMinute = nil
    }

    /// Some networks block 1.1.1.1 specifically. If it keeps failing
    /// while the router is fine, try 8.8.8.8 instead of reporting a
    /// permanent internet problem.
    private func trackInternetHostFallback(gatewayOK: Bool, internetOK: Bool) {
        guard internetHost == Self.primaryInternetHost else { return }
        if !internetOK && gatewayOK {
            primaryHostFailures += 1
            if primaryHostFailures >= Self.fallbackAfterFailures {
                internetHost = Self.fallbackInternetHost
            }
        } else if internetOK {
            primaryHostFailures = 0
        }
    }

    private func writeMinuteAggregateIfDue(now: Date, networkId: String) {
        let minute = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
        defer { currentMinute = minute }
        guard let previous = currentMinute, previous != minute, let lastRoundAt else { return }
        store.append(MinuteAggregate(
            minute: previous,
            networkId: networkId,
            gateway: stats.stats(hop: .gateway, window: 60, now: lastRoundAt),
            internet: stats.stats(hop: .internet, window: 60, now: lastRoundAt),
            channel: lastLink?.channel,
            band: lastLink?.band,
            rssi: lastLink?.rssi,
            noise: lastLink?.noise
        ))
    }
}
