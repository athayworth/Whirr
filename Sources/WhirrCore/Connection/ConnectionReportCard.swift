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
            let link = before.isWired ? "Your Mac's wired link to the router" : "Your Mac's Wi-Fi link to the router"
            let fix: String
            if before.isWired {
                fix = "Check the cable and the router."
            } else if let l = r.link, isWeak(l) {
                fix = "Your signal was weak during the test (\(l.snr) dB above background noise). Improving it is the first thing to try."
            } else {
                fix = "Common causes are a crowded channel, a weak signal, or interference. The Wi-Fi crowding row below shows how busy your channel was."
            }
            return row(grade(g), "\(link) stalled \(before.gateway.spikes) times in the 10 minutes before the test.", fix)
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
        guard !sharing.isEmpty else {
            return row(.unknown, "The scan didn't hear any networks on your stretch of airwaves — not even yours — so it was incomplete. Run the test again.")
        }
        let loud = sharing.filter { $0.rssi >= loudRssi }.count
        let grade: Grade = loud <= 2 ? .good : loud <= 5 ? .ok : .poor
        let n = sharing.count
        var explanation = "During the test, Whirr heard \(n) Wi-Fi network\(n == 1 ? "" : "s") using the same stretch of airwaves as yours (\(link.band) \(mine.label)), including yours. \(loud) \(loud == 1 ? "was" : "were") strong enough to make your router wait its turn. One router can broadcast more than one network, and a single scan can miss some."
        guard grade != .good else { return row(grade, explanation) }

        guard wifiWasTroubled(r) else {
            explanation += " Your Wi-Fi link to the router was steady around this test, so this crowding wasn't causing problems."
            return row(grade, explanation)
        }
        return row(grade, explanation, quieterStretches(neighbors: neighbors, mine: mine, myLoud: loud))
    }

    /// Evidence that the Wi-Fi side had trouble: router-hop stalls before
    /// the test, or the router hop carrying the delay under load.
    static func wifiWasTroubled(_ r: ConnectionTestResult) -> Bool {
        if let b = r.before, b.gatewayPingable, [.minor, .stalling].contains(HopHealth(b.gateway)) { return true }
        return underLoad(r).grade != .good && loadSide(r) == .insideHome
    }

    private static func quieterStretches(neighbors: [NeighborNetwork], mine: ChannelBlock, myLoud: Int) -> String {
        func loudCount(_ block: ChannelBlock) -> Int {
            neighbors.filter { $0.rssi >= loudRssi && WiFiSpectrum.overlaps($0.block, block) }.count
        }
        // "Quieter" means at most half as many loud networks as yours has
        // besides your own — a one-network difference is scan noise.
        let others = max(0, myLoud - 1)
        let options = WiFiSpectrum.candidateBlocks(band: mine.band, widthMHz: mine.widthMHz)
            .filter { !WiFiSpectrum.overlaps($0, mine) }
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
        var fix = "Your Wi-Fi had trouble, so if your router lets you choose a channel, pick a quieter stretch: \(list)."
        if options.contains(where: { $0.block.isRadarShared }) {
            fix += " Channels 52–144 are shared with radar: if the router detects radar it has to move, dropping Wi-Fi for a minute or more."
        }
        return fix
    }
}
