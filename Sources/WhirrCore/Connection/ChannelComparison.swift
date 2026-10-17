import Foundation

/// The stretch of airwaves a router was on: its band and the channels its
/// width covers. Grouping by this (not by primary channel number) means a
/// router that hops 36 → 44 at 80 MHz is correctly seen as never moving.
public struct ChannelGroup: Hashable, Sendable {
    public let band: String
    public let channels: ClosedRange<Int>
    /// nil for history recorded before Whirr stored widths; such minutes
    /// are kept apart rather than guessed into a block.
    public let widthMHz: Int?

    public init(band: String, channel: Int, widthMHz: Int?) {
        self.band = band
        self.widthMHz = widthMHz
        if let widthMHz {
            channels = WiFiSpectrum.occupied(band: band, channel: channel, widthMHz: widthMHz).channels
        } else {
            channels = channel...channel
        }
    }

    public init(link: WiFiLink) {
        self.init(band: link.band, channel: link.channel, widthMHz: link.widthMHz)
    }

    init?(_ agg: MinuteAggregate) {
        guard let channel = agg.channel, let band = agg.band else { return nil }
        self.init(band: band, channel: channel, widthMHz: agg.widthMHz)
    }

    /// "5 GHz channels 149–161", "5 GHz channel 36", or
    /// "5 GHz channel 36 (width not recorded)".
    public var label: String {
        let range = channels.count > 1
            ? "channels \(channels.lowerBound)–\(channels.upperBound)"
            : "channel \(channels.lowerBound)"
        return "\(band) \(range)" + (widthMHz == nil ? " (width not recorded)" : "")
    }
}

public struct ChannelStat: Equatable, Sendable {
    public let group: ChannelGroup
    /// Distinct days with ≥ 30 measured minutes on this stretch in the period.
    public let sessions: Int
    public let spikesPerHour: Double
    public let lossPercent: Double
}

public struct ChannelNeed: Equatable, Sendable {
    public let group: ChannelGroup
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
    /// The current stretch's last 3 sessions had ≥ 2× its earlier typical
    /// stall rate.
    public let currentChannelWorsened: Bool

    public static func compute(
        _ aggregates: [MinuteAggregate],
        networkId: String,
        current: ChannelGroup?,
        period: Period,
        calendar: Calendar = .current
    ) -> ChannelComparison {
        // Only minutes where the router hop was actually measured: a
        // minute with no pings has no stalls to count, and would make a
        // stretch look calmer than it was.
        let relevant = aggregates.filter {
            $0.networkId == networkId && $0.gateway.count > 0
                && period.hours.contains(calendar.component(.hour, from: $0.minute))
        }

        // group → day → minutes
        var byGroup: [ChannelGroup: [Date: [MinuteAggregate]]] = [:]
        for agg in relevant {
            guard let group = ChannelGroup(agg) else { continue }
            byGroup[group, default: [:]][calendar.startOfDay(for: agg.minute), default: []].append(agg)
        }

        var qualified: [ChannelStat] = []
        var insufficient: [ChannelNeed] = []
        var worsened = false
        for (group, days) in byGroup {
            let sessions = days
                .filter { $0.value.count >= minSessionMinutes }
                .sorted { $0.key < $1.key }
                .map(\.value)
            guard sessions.count >= minSessions else {
                insufficient.append(ChannelNeed(group: group, sessionsNeeded: minSessions - sessions.count))
                continue
            }
            let minutes = sessions.flatMap { $0 }
            qualified.append(ChannelStat(
                group: group,
                sessions: sessions.count,
                spikesPerHour: spikesPerHour(minutes),
                lossPercent: minutes.map(\.gateway.lossPercent).reduce(0, +) / Double(minutes.count)
            ))
            if group == current, sessions.count >= minSessions * 2 {
                let rates = sessions.map(spikesPerHour)
                let recent = rates.suffix(minSessions).reduce(0, +) / Double(minSessions)
                let prior = ConnectionStats.median(rates.dropLast(minSessions).sorted()) ?? 0
                worsened = recent >= 2 * max(prior, 1)
            }
        }
        return ChannelComparison(
            period: period,
            qualified: qualified.sorted {
                ($0.spikesPerHour, $0.group.band, $0.group.channels.lowerBound)
                    < ($1.spikesPerHour, $1.group.band, $1.group.channels.lowerBound)
            },
            insufficient: insufficient.sorted {
                ($0.group.band, $0.group.channels.lowerBound) < ($1.group.band, $1.group.channels.lowerBound)
            },
            currentChannelWorsened: worsened
        )
    }

    private static func spikesPerHour(_ minutes: [MinuteAggregate]) -> Double {
        guard !minutes.isEmpty else { return 0 }
        return Double(minutes.map(\.gateway.spikes).reduce(0, +)) / (Double(minutes.count) / 60)
    }
}
