import Foundation

public enum ConnectionTitles {
    public static let spikyWiFi = "Your link to the router is stalling"
    public static let pastRouter = "Problem is past your router"
    public static let weakSignal = "Weak Wi-Fi signal"
    public static let outage = "Internet is down"
}

public struct ConnectionRuleConfig: Codable, Sendable, Equatable {
    public let enabled: Bool
    /// Router-hop spikes in 10 min for warning / critical.
    public let spikyWarnSpikes: Int
    public let spikyCritSpikes: Int
    /// Router-hop loss % in 10 min for warning / critical.
    public let spikyWarnLoss: Double
    public let spikyCritLoss: Double
    /// Router hop counts as "clean" below these (for "past your router").
    public let cleanMaxSpikes: Int
    public let cleanMaxLoss: Double
    public let weakRssi: Int
    public let weakSnr: Int
    /// Pings needed in the 10-min window before judging (30 = 1 min).
    public let minSamples: Int

    public init(enabled: Bool = true, spikyWarnSpikes: Int = 6, spikyCritSpikes: Int = 20,
                spikyWarnLoss: Double = 2, spikyCritLoss: Double = 5, cleanMaxSpikes: Int = 3,
                cleanMaxLoss: Double = 1, weakRssi: Int = -72, weakSnr: Int = 20, minSamples: Int = 30) {
        self.enabled = enabled
        self.spikyWarnSpikes = spikyWarnSpikes
        self.spikyCritSpikes = spikyCritSpikes
        self.spikyWarnLoss = spikyWarnLoss
        self.spikyCritLoss = spikyCritLoss
        self.cleanMaxSpikes = cleanMaxSpikes
        self.cleanMaxLoss = cleanMaxLoss
        self.weakRssi = weakRssi
        self.weakSnr = weakSnr
        self.minSamples = minSamples
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ConnectionRuleConfig()
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        self.spikyWarnSpikes = try c.decodeIfPresent(Int.self, forKey: .spikyWarnSpikes) ?? d.spikyWarnSpikes
        self.spikyCritSpikes = try c.decodeIfPresent(Int.self, forKey: .spikyCritSpikes) ?? d.spikyCritSpikes
        self.spikyWarnLoss = try c.decodeIfPresent(Double.self, forKey: .spikyWarnLoss) ?? d.spikyWarnLoss
        self.spikyCritLoss = try c.decodeIfPresent(Double.self, forKey: .spikyCritLoss) ?? d.spikyCritLoss
        self.cleanMaxSpikes = try c.decodeIfPresent(Int.self, forKey: .cleanMaxSpikes) ?? d.cleanMaxSpikes
        self.cleanMaxLoss = try c.decodeIfPresent(Double.self, forKey: .cleanMaxLoss) ?? d.cleanMaxLoss
        self.weakRssi = try c.decodeIfPresent(Int.self, forKey: .weakRssi) ?? d.weakRssi
        self.weakSnr = try c.decodeIfPresent(Int.self, forKey: .weakSnr) ?? d.weakSnr
        self.minSamples = try c.decodeIfPresent(Int.self, forKey: .minSamples) ?? d.minSamples
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, spikyWarnSpikes, spikyCritSpikes, spikyWarnLoss, spikyCritLoss
        case cleanMaxSpikes, cleanMaxLoss, weakRssi, weakSnr, minSamples
    }
}

/// The router hop stalls or drops pings: the problem is inside the home.
struct SpikyWiFiRule: Rule {
    let config: ConnectionRuleConfig
    var isEnabled: Bool { config.enabled }

    func evaluate(_ ctx: CoreContext) -> Diagnosis? {
        guard let c = ctx.connection, c.currentOutage == nil, c.link != nil, c.gatewayPingable else { return nil }
        let g = c.gateway10m
        guard g.count >= config.minSamples else { return nil }
        let critical = g.spikes >= config.spikyCritSpikes || g.lossPercent >= config.spikyCritLoss
        let warning = g.spikes >= config.spikyWarnSpikes || g.lossPercent >= config.spikyWarnLoss
        guard critical || warning else { return nil }
        return Diagnosis(
            title: ConnectionTitles.spikyWiFi,
            detail: String(
                format: "In the last 10 minutes, the link between your Mac and your router stalled %d times (%.0f%% of checks lost). Stalls like these make games and video calls stutter. They're inside your home: usually Wi-Fi (a crowded channel or a weak signal), sometimes this Mac or the router. The connection test shows more.",
                g.spikes, g.lossPercent
            ),
            severity: critical ? .critical : .warning,
            area: .connection,
            action: SuggestedAction(label: "Check my connection", kind: .runConnectionTest)
        )
    }
}

/// Router hop clean, internet hop not: the provider's side.
struct PastRouterRule: Rule {
    let config: ConnectionRuleConfig
    var isEnabled: Bool { config.enabled }

    func evaluate(_ ctx: CoreContext) -> Diagnosis? {
        // When the router ignores pings we can't tell the legs apart.
        guard let c = ctx.connection, c.currentOutage == nil, c.gatewayPingable else { return nil }
        let g = c.gateway10m, i = c.internet10m
        guard g.count >= config.minSamples, i.count >= config.minSamples else { return nil }
        guard g.spikes < config.cleanMaxSpikes, g.lossPercent < config.cleanMaxLoss else { return nil }
        let critical = i.spikes >= config.spikyCritSpikes || i.lossPercent >= config.spikyCritLoss
        let warning = i.spikes >= config.spikyWarnSpikes || i.lossPercent >= config.spikyWarnLoss
        guard critical || warning else { return nil }
        return Diagnosis(
            title: ConnectionTitles.pastRouter,
            detail: String(
                format: "Your Mac's connection to the router is clean, but the connection beyond it stalled %d times in the last 10 minutes (%.0f%% of checks lost). Possible causes: heavy uploads or downloads on your network (backups, cloud sync, other devices), the router or modem, or your internet provider.",
                i.spikes, i.lossPercent
            ),
            severity: critical ? .critical : .warning,
            area: .connection,
            action: SuggestedAction(label: "What to check", kind: .showHowTo(.talkToISP))
        )
    }
}

/// Signal too weak or too close to the background noise. A contributing
/// factor, never an emergency on its own — so warning at most. The
/// verdict's 2-minute gate supplies the "sustained" requirement.
struct WeakSignalRule: Rule {
    let config: ConnectionRuleConfig
    var isEnabled: Bool { config.enabled }

    func evaluate(_ ctx: CoreContext) -> Diagnosis? {
        guard let link = ctx.connection?.link else { return nil }
        guard link.rssi < config.weakRssi || link.snr < config.weakSnr else { return nil }
        return Diagnosis(
            title: ConnectionTitles.weakSignal,
            detail: "Your Wi-Fi signal is \(link.rssi) dBm, \(link.snr) dB above the background noise. Below about \(config.weakRssi) dBm or \(config.weakSnr) dB, connections can slow down and drop.",
            severity: .warning,
            area: .connection,
            action: SuggestedAction(label: "Ways to improve the signal", kind: .showHowTo(.improveSignal))
        )
    }
}

struct OutageRule: Rule {
    let config: ConnectionRuleConfig
    var isEnabled: Bool { config.enabled }

    func evaluate(_ ctx: CoreContext) -> Diagnosis? {
        guard let outage = ctx.connection?.currentOutage else { return nil }
        let detail: String
        let howTo: SuggestedAction.HowTo
        switch outage.cause {
        case .router:
            detail = "Your router stopped responding. Restarting it usually brings it back. Whirr is logging this so you can tell how often it happens."
            howTo = .routerOutage
        case .isp:
            detail = "Your router answers, but nothing beyond it does. The break is between your router and the internet: the router's internet connection, the modem, or your provider. Whirr is logging this so you have dates and times."
            howTo = .ispOutage
        case .wifiDisconnected:
            detail = "Your Mac lost its Wi-Fi connection."
            howTo = .wifiDropped
        case .unknown:
            detail = "Nothing beyond your Mac is reachable. Your router doesn't answer Whirr's checks, so Whirr can't tell whether the router or the internet line is at fault."
            howTo = .connectionDown
        }
        return Diagnosis(
            title: ConnectionTitles.outage,
            detail: detail,
            severity: .critical,
            area: .connection,
            action: SuggestedAction(label: "What to do", kind: .showHowTo(howTo))
        )
    }
}
