import Foundation

public enum Grade: String, Codable, Sendable {
    case good, ok, poor, unknown
}

public struct ReportRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let grade: Grade
    public let explanation: String
    /// What to do about it; nil when nothing needs doing.
    public let fix: String?
}

/// Turns one saved test into four plain-English rows. Every row uses only
/// what that test (and the 10 minutes before it) measured, and names a
/// cause only when the measurements isolate it.
public enum ConnectionReportCard {
    /// About what game/video streaming needs.
    static let streamingNeedMbps = 25.0
    /// Neighbours heard at least this loud make Wi-Fi radios wait for each
    /// other (the standard "channel busy" detection level).
    static let loudRssi = -82
    /// Pings needed on the router hop before a test attributes delay to it.
    static let minLoadPings = 10

    public static func rows(for r: ConnectionTestResult) -> [ReportRow] {
        [speed(r), stability(r), underLoad(r), crowding(r)]
    }

    // MARK: Speed

    static func speed(_ r: ConnectionTestResult) -> ReportRow {
        guard let down = r.nq?.downMbps else {
            return ReportRow(id: "speed", title: "Speed", grade: .unknown,
                             explanation: "Couldn't measure speed this time.", fix: nil)
        }
        let up = r.nq?.upMbps.map { String(format: ", upload %.0f Mbps", $0) } ?? ""
        let grade: Grade = down >= 50 ? .good : down >= streamingNeedMbps ? .ok : .poor
        return ReportRow(
            id: "speed", title: "Speed", grade: grade,
            explanation: String(format: "Download %.0f Mbps%@. Game and video streaming generally need about 25–45 Mbps.", down, up),
            fix: grade == .poor ? "Check whether others at home are downloading, then ask your provider what speed your plan should deliver." : nil
        )
    }

    // MARK: Stability

    static func stability(_ r: ConnectionTestResult) -> ReportRow {
        func row(_ grade: Grade, _ explanation: String, _ fix: String? = nil) -> ReportRow {
            ReportRow(id: "stability", title: "Stability", grade: grade, explanation: explanation, fix: fix)
        }
        guard let before = r.before else {
            return row(.unknown, "Background stability from before this test wasn't recorded — it ran on an older version of Whirr.")
        }
        let g = before.gatewayPingable ? HopHealth(before.gateway) : .measuring
        let i = HopHealth(before.internet)
        if g == .measuring && i == .measuring {
            return row(.unknown, "Whirr hadn't been watching long enough before this test to judge stability.")
        }
        if g == .minor || g == .stalling {
            let link = before.isWired ? "The wired link between your Mac and the router" : "The link between your Mac and the router"
            var explanation = "\(link) stalled \(before.gateway.spikes) times in the 10 minutes before the test."
            // Don't let a few router-hop stalls hide many more beyond it.
            if i.isWorse(than: g) {
                explanation += " The connection beyond the router stalled \(before.internet.spikes) times."
            }
            let fix: String
            if before.isWired {
                fix = "Check the cable and the router."
            } else if let l = r.link, isWeak(l) {
                fix = "Your signal was weak during the test (\(l.snr) dB above background noise). Improving it is the first thing to try."
            } else {
                fix = "Stalls here are inside your home: Wi-Fi, this Mac, or the router. Common causes on Wi-Fi are a crowded channel, a weak signal, or interference — the Wi-Fi crowding row below shows how busy your channel was."
            }
            return row(grade(i.isWorse(than: g) ? i : g), explanation, fix)
        }
        if i == .minor || i == .stalling {
            guard g == .steady else {
                return row(grade(i),
                           "Your connection stalled \(before.internet.spikes) times in the 10 minutes before the test. Your router doesn't answer Whirr's checks, so Whirr can't tell whether that was inside your home or beyond it.",
                           "If other devices at home stall at the same times, the cause is more likely beyond this Mac.")
            }
            return row(grade(i),
                       "Your Mac's link to the router was steady, but the connection beyond the router stalled \(before.internet.spikes) times in the 10 minutes before the test.",
                       "Possible causes: heavy uploads or downloads on your network (backups, cloud sync, other devices), the router or modem, or your provider. If it keeps happening while nothing else is busy, tell your provider.")
        }
        return row(.good, "Steady in the 10 minutes before the test.")
    }

    private static func grade(_ h: HopHealth) -> Grade {
        switch h {
        case .steady: return .good
        case .minor: return .ok
        case .stalling: return .poor
        case .measuring: return .unknown
        }
    }

    static func isWeak(_ link: WiFiLink, config: ConnectionRuleConfig = ConnectionRuleConfig()) -> Bool {
        link.rssi < config.weakRssi || link.snr < config.weakSnr
    }

    // MARK: Under load

    enum LoadSide { case insideHome, beyondRouter }

    /// Where the extra delay under load showed up — nil when the test
    /// didn't measure the router hop well enough to say.
    static func loadSide(_ r: ConnectionTestResult) -> LoadSide? {
        guard let idle = r.nq?.idleLatencyMs, let loaded = r.nq?.loadedLatencyMs,
              r.gatewayIdle.count >= minLoadPings, r.gatewayLoaded.count >= minLoadPings,
              let gwIdle = r.gatewayIdle.medianMs, let gwLoaded = r.gatewayLoaded.medianMs else { return nil }
        let delta = max(0, loaded - idle)
        return max(0, gwLoaded - gwIdle) >= delta * 0.5 ? .insideHome : .beyondRouter
    }

    static func underLoad(_ r: ConnectionTestResult) -> ReportRow {
        guard let idle = r.nq?.idleLatencyMs, let loaded = r.nq?.loadedLatencyMs else {
            return ReportRow(id: "underLoad", title: "Under load", grade: .unknown,
                             explanation: "Couldn't measure delay under load this time.", fix: nil)
        }
        let delta = max(0, loaded - idle)
        let grade: Grade = delta < 30 ? .good : delta < 100 ? .ok : .poor
        let summary = String(format: "Delay went from %.0f ms when quiet to %.0f ms when the connection was busy.", idle, loaded)
        guard grade != .good else {
            return ReportRow(id: "underLoad", title: "Under load", grade: grade, explanation: summary, fix: nil)
        }
        switch loadSide(r) {
        case .insideHome:
            return ReportRow(
                id: "underLoad", title: "Under load", grade: grade,
                explanation: summary + " At least half of that rise also showed up between your Mac and the router — on your Wi-Fi, in this Mac, or in the router itself, not out on the internet line.",
                fix: "Pause big downloads and uploads on this Mac while gaming."
            )
        case .beyondRouter:
            return ReportRow(
                id: "underLoad", title: "Under load", grade: grade,
                explanation: summary + " Most of that rise happened beyond the router — on the internet line or in the router's connection to it.",
                fix: "Lower your game-streaming quality a notch so it doesn't fill the line, and pause big downloads and uploads (backups, cloud sync) while playing."
            )
        case nil:
            return ReportRow(
                id: "underLoad", title: "Under load", grade: grade, explanation: summary,
                fix: "Pause big downloads and uploads while gaming, and lower your game-streaming quality a notch."
            )
        }
    }

    // MARK: Crowding

    static func crowding(_ r: ConnectionTestResult) -> ReportRow {
        func row(_ grade: Grade, _ explanation: String, _ fix: String? = nil) -> ReportRow {
            ReportRow(id: "crowding", title: "Wi-Fi crowding", grade: grade, explanation: explanation, fix: fix)
        }
        guard let link = r.link else {
            return row(.unknown, r.before?.isWired == true ? "Wired — not applicable." : "This Mac wasn't connected to Wi-Fi during the test.")
        }
        guard let neighbors = r.neighbors else {
            return row(.unknown, "Nearby Wi-Fi wasn't recorded for this test. Run the test again to see it.")
        }
        let mine = WiFiSpectrum.occupied(band: link.band, channel: link.channel, widthMHz: link.widthMHz)
        let sharing = neighbors.filter { WiFiSpectrum.overlaps($0.block, mine) }
        let namesKnown = neighbors.contains { $0.isYours != nil }
        let ownHeard = namesKnown ? sharing.contains { $0.isYours == true } : !sharing.isEmpty
        guard ownHeard else {
            return row(.unknown, "The scan didn't hear your own network on your stretch of airwaves, so it was incomplete. Run the test again.")
        }
        // Loud networks other than yours. Without names, one entry is
        // assumed to be yours (it was heard: see ownHeard).
        let loudOthers: Int
        var explanation: String
        let place = "(\(link.band) \(mine.label))"
        if namesKnown {
            let others = sharing.filter { $0.isYours != true }
            loudOthers = others.filter { $0.rssi >= loudRssi }.count
            explanation = "During the test, Whirr heard \(others.count) other Wi-Fi network\(others.count == 1 ? "" : "s") using the same stretch of airwaves as yours \(place). \(loudOthers) \(loudOthers == 1 ? "was" : "were") loud enough at your Mac to compete for airtime. One router can broadcast more than one network, and a single scan can miss some."
        } else {
            let loud = sharing.filter { $0.rssi >= loudRssi }.count
            loudOthers = max(0, loud - 1)
            let n = sharing.count
            explanation = "During the test, Whirr heard \(n) Wi-Fi network\(n == 1 ? "" : "s") using the same stretch of airwaves as yours \(place), including yours. \(loud) \(loud == 1 ? "was" : "were") loud enough at your Mac to compete for airtime (counting yours). One router can broadcast more than one network, and a single scan can miss some."
        }
        let grade: Grade = loudOthers <= 1 ? .good : loudOthers <= 4 ? .ok : .poor
        guard grade != .good else { return row(grade, explanation) }

        switch routerLinkEvidence(r) {
        case .steady:
            explanation += " The link between your Mac and the router was steady before this test, so this crowding wasn't causing problems."
            return row(grade, explanation)
        case .unknown:
            explanation += " Whirr couldn't check the link between your Mac and the router around this test, so it can't say whether this crowding was causing problems."
            return row(grade, explanation)
        case .troubled:
            return row(grade, explanation, quieterStretches(neighbors: neighbors, mine: mine, loudOthers: loudOthers))
        }
    }

    enum RouterLinkEvidence { case troubled, steady, unknown }

    /// What the test (and the 10 minutes before it) showed about the link
    /// between the Mac and the router. "Steady" needs a measured, clean
    /// router hop — never assumed from missing data.
    static func routerLinkEvidence(_ r: ConnectionTestResult) -> RouterLinkEvidence {
        let health = r.before.flatMap { $0.gatewayPingable ? HopHealth($0.gateway) : nil }
        if health == .minor || health == .stalling { return .troubled }
        if underLoad(r).grade != .good && loadSide(r) == .insideHome { return .troubled }
        return health == .steady ? .steady : .unknown
    }

    private static func quieterStretches(neighbors: [NeighborNetwork], mine: ChannelBlock, loudOthers others: Int) -> String {
        func loudCount(_ block: ChannelBlock) -> Int {
            neighbors.filter { $0.isYours != true && $0.rssi >= loudRssi && WiFiSpectrum.overlaps($0.block, block) }.count
        }
        // "Quieter" means at most half as many loud networks as yours has
        // besides your own — a one-network difference is scan noise.
        let alternatives = WiFiSpectrum.candidateBlocks(band: mine.band, widthMHz: mine.widthMHz)
            .filter { !WiFiSpectrum.overlaps($0, mine) }
        guard !alternatives.isEmpty else {
            return "The link to your router had trouble, but Whirr can't compare other channels for \(mine.band) at this width, so it has no channel to suggest."
        }
        let options = alternatives
            .map { (block: $0, loud: loudCount($0)) }
            .filter { $0.loud * 2 <= others }
            .sorted { ($0.loud, $0.block.isRadarShared ? 1 : 0, $0.block.channels.lowerBound)
                    < ($1.loud, $1.block.isRadarShared ? 1 : 0, $1.block.channels.lowerBound) }
            .prefix(2)
        guard !options.isEmpty else {
            return "Every other stretch Whirr heard was about as busy, so changing channel is unlikely to help."
        }
        let list = options.map { o in
            let where_ = o.block.channels.count > 1 ? " (\(o.block.label))" : ""
            return "channel \(o.block.channels.lowerBound)\(where_), \(o.loud) strong network\(o.loud == 1 ? "" : "s") heard"
        }.joined(separator: "; or ")
        var fix = "The link to your router had trouble, so if your router lets you choose a channel, a quieter stretch may help: \(list)."
        if options.contains(where: { $0.block.isRadarShared }) {
            fix += " Channels 52–144 are shared with radar: if the router detects radar it has to move, which can drop Wi-Fi for a minute or more."
        }
        return fix
    }
}
