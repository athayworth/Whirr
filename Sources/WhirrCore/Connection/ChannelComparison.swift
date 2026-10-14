import Foundation

public struct ChannelStat: Equatable, Sendable {
    public let channel: Int
    public let band: String
    /// Distinct days with ≥ 30 minutes of data on this channel in the period.
    public let sessions: Int
    public let spikesPerHour: Double
    public let lossPercent: Double
}

public struct ChannelNeed: Equatable, Sendable {
    public let channel: Int
    public let sessionsNeeded: Int
}

/// Compares how each Wi-Fi channel has performed on one network, at
/// comparable times of day. It's evidence, not a verdict: neighbors'
/// routers move too, so the numbers are a living comparison.
public struct ChannelComparison: Equatable, Sendable {
    public enum Period: String, Sendable, CaseIterable {
        case evening, daytime

        var hours: Range<Int> {
            switch self {
            case .evening: return 17..<23
            case .daytime: return 9..<17
            }
        }
    }

    static let minSessionMinutes = 30
    static let minSessions = 3

    public let period: Period
    /// Channels with enough data, best (fewest spikes/hour) first.
    public let qualified: [ChannelStat]
    /// Channels seen but without enough sessions yet.
    public let insufficient: [ChannelNeed]
    /// The current channel's last 3 sessions are ≥ 2× its earlier typical.
    public let currentChannelWorsened: Bool

    public static func compute(
        _ aggregates: [MinuteAggregate],
        networkId: String,
        currentChannel: Int?,
        period: Period,
        calendar: Calendar = .current
    ) -> ChannelComparison {
        let relevant = aggregates.filter {
            $0.networkId == networkId && $0.channel != nil
                && period.hours.contains(calendar.component(.hour, from: $0.minute))
        }

        // channel → day → minutes
        var byChannel: [Int: [Date: [MinuteAggregate]]] = [:]
        for agg in relevant {
            byChannel[agg.channel!, default: [:]][calendar.startOfDay(for: agg.minute), default: []].append(agg)
        }

        var qualified: [ChannelStat] = []
        var insufficient: [ChannelNeed] = []
        var worsened = false
        for (channel, days) in byChannel {
            let sessions = days
                .filter { $0.value.count >= minSessionMinutes }
                .sorted { $0.key < $1.key }
                .map(\.value)
            guard sessions.count >= minSessions else {
                insufficient.append(ChannelNeed(channel: channel, sessionsNeeded: minSessions - sessions.count))
                continue
            }
            let minutes = sessions.flatMap { $0 }
            qualified.append(ChannelStat(
                channel: channel,
                band: minutes.first?.band ?? "",
                sessions: sessions.count,
                spikesPerHour: spikesPerHour(minutes),
                lossPercent: minutes.map(\.gateway.lossPercent).reduce(0, +) / Double(minutes.count)
            ))
            if channel == currentChannel, sessions.count >= minSessions * 2 {
                let rates = sessions.map(spikesPerHour)
                let recent = rates.suffix(minSessions).reduce(0, +) / Double(minSessions)
                let prior = ConnectionStats.median(rates.dropLast(minSessions).sorted()) ?? 0
                worsened = recent >= 2 * max(prior, 1)
            }
        }
        return ChannelComparison(
            period: period,
            qualified: qualified.sorted { ($0.spikesPerHour, $0.channel) < ($1.spikesPerHour, $1.channel) },
            insufficient: insufficient.sorted { $0.channel < $1.channel },
            currentChannelWorsened: worsened
        )
    }

    private static func spikesPerHour(_ minutes: [MinuteAggregate]) -> Double {
        guard !minutes.isEmpty else { return 0 }
        return Double(minutes.map(\.gateway.spikes).reduce(0, +)) / (Double(minutes.count) / 60)
    }
}
