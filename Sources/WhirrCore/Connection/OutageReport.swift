import Foundation

/// Plain-language outage text for the lists and the summary a user can
/// paste to their provider. Causes recorded by the older single-ping
/// method are labelled as such and not counted as evidence.
public enum OutageReport {
    public static func cause(_ o: OutageRecord) -> String {
        let text: String
        switch o.cause {
        case .router: text = "Router stopped responding"
        case .isp: text = "Down beyond the router (router answered)"
        case .wifiDisconnected: text = "Wi-Fi disconnected"
        case .unknown: text = "Connection down (cause unclear)"
        }
        return o.causeIsReliable ? text : text + " — cause from an older, less reliable method"
    }

    public static func duration(_ o: OutageRecord) -> String {
        guard let d = o.duration else { return "ongoing" }
        let seconds = Int(d)
        if seconds < 60 { return "\(max(0, seconds))s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }

    public static func summary(_ outages: [OutageRecord], now: Date = Date()) -> String {
        let recent = outages.filter { $0.start > now.addingTimeInterval(-30 * 86_400) }.sorted { $0.start < $1.start }
        let lines = recent.map { "• \($0.start.formatted(date: .abbreviated, time: .shortened)) — \(cause($0)), \(duration($0))" }
        let reliable = recent.filter(\.causeIsReliable)
        let beyond = reliable.filter { $0.cause == .isp }.count
        let older = recent.count - reliable.count
        var text = "Connection outages in the last 30 days: \(recent.count)"
        text += reliable.isEmpty ? "." : " (\(beyond) where the home router still answered but nothing beyond it did)."
        text += "\n\n" + lines.joined(separator: "\n") + "\n\n"
        text += "Recorded automatically by Whirr, which checks the home router and two internet servers (1.1.1.1 and 8.8.8.8) every 2 seconds."
        if older > 0 {
            text += " \(older) of these \(older == 1 ? "was" : "were") recorded by an older version of Whirr that judged the cause from a single check, so \(older == 1 ? "its" : "their") cause is less reliable and isn't counted above."
        }
        return text
    }
}
