import Foundation

/// "Today, which side had trouble?" in one sentence, from today's minute
/// history on the current network. It names a side only when the router
/// hop was measured and isolates it.
public struct DaySummary: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        case notEnoughData
        case steady
        /// Router hop clean, path beyond it not.
        case beyondRouter
        /// Router hop itself stalled.
        case insideHome
        /// Stalls, but the router never answered, so no split is possible.
        case cantSeparate
    }

    /// The same "clean" line the findings use (3 stalls per 10 minutes),
    /// as an hourly rate.
    static let cleanStallsPerHour = 18.0
    static let cleanLossPercent = 1.0
    static let minMinutes = 30

    public let verdict: Verdict
    public let sentence: String
    public let minutesWatched: Int

    public static func compute(_ aggregates: [MinuteAggregate], networkId: String, now: Date,
                               calendar: Calendar = .current) -> DaySummary {
        let start = calendar.startOfDay(for: now)
        let today = aggregates.filter { $0.networkId == networkId && $0.minute >= start && $0.minute <= now }
        let watched = today.filter { $0.internet.count > 0 }
        let routerMeasured = today.filter { $0.gateway.count > 0 }
        let minutes = watched.count

        guard minutes >= minMinutes else {
            let sentence = minutes == 0
                ? "Whirr hasn't watched your connection yet today."
                : "Not enough data yet today — Whirr has watched for \(minutes) minute\(minutes == 1 ? "" : "s")."
            return DaySummary(verdict: .notEnoughData, sentence: sentence, minutesWatched: minutes)
        }

        let duration = minutes < 120 ? "\(minutes) minutes" : String(format: "%.1f hours", Double(minutes) / 60)
        let i = totals(watched, \.internet)
        let routerKnown = routerMeasured.count >= minMinutes
        let g = totals(routerMeasured, \.gateway)

        let verdict: Verdict
        let sentence: String
        if routerKnown && !g.clean {
            verdict = .insideHome
            sentence = "Your Mac's link to the router stalled \(times(g.spikes)) over \(duration) today, so at least part of the trouble was inside your home (Wi-Fi, this Mac, or the router)."
        } else if !i.clean && routerKnown {
            verdict = .beyondRouter
            sentence = "Your Mac's link to the router was steady today, but the connection beyond it stalled \(times(i.spikes)) over \(duration)."
        } else if !i.clean {
            verdict = .cantSeparate
            sentence = "Your connection stalled \(times(i.spikes)) over \(duration) today. Your router doesn't answer Whirr's checks, so Whirr can't tell whether that was inside your home or beyond it."
        } else {
            verdict = .steady
            sentence = routerKnown
                ? "Steady today: \(g.spikes) stall\(g.spikes == 1 ? "" : "s") between your Mac and the router, and \(i.spikes) on the full path to the internet, over \(duration)."
                : "Steady today: \(i.spikes) stall\(i.spikes == 1 ? "" : "s") over \(duration)."
        }
        return DaySummary(verdict: verdict, sentence: sentence, minutesWatched: minutes)
    }

    private static func times(_ n: Int) -> String { n == 1 ? "once" : "\(n) times" }

    private static func totals(_ minutes: [MinuteAggregate], _ hop: KeyPath<MinuteAggregate, HopStats>)
        -> (spikes: Int, clean: Bool) {
        let spikes = minutes.map { $0[keyPath: hop].spikes }.reduce(0, +)
        let pings = minutes.map { $0[keyPath: hop].count }.reduce(0, +)
        let lost = minutes.map { $0[keyPath: hop].lossPercent * Double($0[keyPath: hop].count) }.reduce(0, +)
        let lossPercent = pings > 0 ? lost / Double(pings) : 0
        let perHour = minutes.isEmpty ? 0 : Double(spikes) / (Double(minutes.count) / 60)
        return (spikes, perHour < cleanStallsPerHour && lossPercent < cleanLossPercent)
    }
}
