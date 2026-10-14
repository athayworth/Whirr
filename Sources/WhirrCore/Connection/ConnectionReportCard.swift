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

/// Turns raw test results into four plain-English rows.
public enum ConnectionReportCard {
    /// About what game/video streaming needs.
    static let streamingNeedMbps = 25.0
    static let nonDFS5GHz = [36, 40, 44, 48]
    static let channels24GHz = [1, 6, 11]

    public static func rows(for r: ConnectionTestResult, passiveGateway: HopStats, passiveInternet: HopStats) -> [ReportRow] {
        [speed(r), stability(gateway: passiveGateway, internet: passiveInternet), underLoad(r), crowding(r)]
    }

    static func speed(_ r: ConnectionTestResult) -> ReportRow {
        guard let down = r.nq?.downMbps else {
            return ReportRow(id: "speed", title: "Speed", grade: .unknown,
                             explanation: "Couldn't measure speed this time.", fix: nil)
        }
        let up = r.nq?.upMbps.map { String(format: ", upload %.0f Mbps", $0) } ?? ""
        let grade: Grade = down >= 50 ? .good : down >= streamingNeedMbps ? .ok : .poor
        return ReportRow(
            id: "speed", title: "Speed", grade: grade,
            explanation: String(format: "Download %.0f Mbps%@. Game and video streaming need about 25–45 Mbps.", down, up),
            fix: grade == .poor ? "Check whether others at home are downloading, then ask your provider what speed your plan should deliver." : nil
        )
    }

    static func stability(gateway: HopStats, internet: HopStats) -> ReportRow {
        guard gateway.count >= 30 || internet.count >= 30 else {
            return ReportRow(id: "stability", title: "Stability", grade: .unknown,
                             explanation: "Whirr needs a few minutes of background watching to judge stability.", fix: nil)
        }
        func grade(_ h: HopStats) -> Grade {
            guard h.count >= 30 else { return .good }
            if h.spikes < 3 && h.lossPercent < 1 { return .good }
            if h.spikes < 6 && h.lossPercent < 2 { return .ok }
            return .poor
        }
        let g = grade(gateway), i = grade(internet)
        if g != .good {
            return ReportRow(
                id: "stability", title: "Stability", grade: g,
                explanation: "Your Mac's Wi-Fi link to the router stalled \(gateway.spikes) times in the last 10 minutes.",
                fix: "Move the router to a less crowded channel (see Wi-Fi crowding below)."
            )
        }
        if i != .good {
            return ReportRow(
                id: "stability", title: "Stability", grade: i,
                explanation: "Wi-Fi to the router is steady, but the connection beyond it stalled \(internet.spikes) times in the last 10 minutes.",
                fix: "This is on your internet provider's side. Note the times and tell your provider."
            )
        }
        return ReportRow(id: "stability", title: "Stability", grade: .good,
                         explanation: "No stalls in the last 10 minutes, on Wi-Fi or beyond.", fix: nil)
    }

    static func underLoad(_ r: ConnectionTestResult) -> ReportRow {
        guard let idle = r.nq?.idleLatencyMs, let loaded = r.nq?.loadedLatencyMs else {
            return ReportRow(id: "underLoad", title: "Under load", grade: .unknown,
                             explanation: "Couldn't measure delay under load this time.", fix: nil)
        }
        let delta = max(0, loaded - idle)
        let grade: Grade = delta < 30 ? .good : delta < 100 ? .ok : .poor
        let summary = String(format: "Delay goes from %.0f ms when quiet to %.0f ms when the connection is busy.", idle, loaded)
        guard grade != .good else {
            return ReportRow(id: "underLoad", title: "Under load", grade: grade, explanation: summary, fix: nil)
        }
        let gwDelta = max(0, (r.gatewayLoaded.medianMs ?? 0) - (r.gatewayIdle.medianMs ?? 0))
        if gwDelta >= delta * 0.5 {
            return ReportRow(
                id: "underLoad", title: "Under load", grade: grade,
                explanation: summary + " Most of that slowdown happens on your Wi-Fi.",
                fix: "A less crowded Wi-Fi channel helps most. Pausing big downloads while gaming helps too."
            )
        }
        return ReportRow(
            id: "underLoad", title: "Under load", grade: grade,
            explanation: summary + " Most of that slowdown is on the internet line or in the router's queue, not your Wi-Fi.",
            fix: "Lower your game-streaming quality a notch so it doesn't fill the line, and pause big downloads while playing."
        )
    }

    static func crowding(_ r: ConnectionTestResult) -> ReportRow {
        guard let link = r.link else {
            return ReportRow(id: "crowding", title: "Wi-Fi crowding", grade: .unknown,
                             explanation: "Wired — not applicable.", fix: nil)
        }
        func count(_ channel: Int) -> Int {
            r.neighbors.first { $0.channel == channel && $0.band == link.band }?.count ?? 0
        }
        // The scan sees your own network on your channel too.
        let others = max(0, count(link.channel) - 1)
        let grade: Grade = others >= 6 ? .poor : others >= 3 ? .ok : .good
        let explanation = "\(others) other network\(others == 1 ? "" : "s") share\(others == 1 ? "s" : "") your channel (\(link.band) channel \(link.channel))."
        guard grade != .good else {
            return ReportRow(id: "crowding", title: "Wi-Fi crowding", grade: grade, explanation: explanation, fix: nil)
        }
        let candidates = link.band == "2.4 GHz" ? channels24GHz : nonDFS5GHz
        let best = candidates.filter { $0 != link.channel }.min { (count($0), $0) < (count($1), $1) }
        var fix = best.map { "Set your router's \(link.band) channel to \($0) (\(count($0)) neighbors there) instead of automatic." }
            ?? "Set your router to a less crowded channel."
        if link.band == "5 GHz" {
            fix += " Channels 52–144 are often emptier but can briefly drop when the router detects radar."
        }
        return ReportRow(id: "crowding", title: "Wi-Fi crowding", grade: grade, explanation: explanation, fix: fix)
    }
}
