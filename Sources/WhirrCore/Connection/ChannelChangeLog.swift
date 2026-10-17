import Foundation

/// A Wi-Fi link as recorded in one minute of history.
public struct LinkPoint: Equatable, Sendable {
    public let band: String
    public let channel: Int
    /// nil in history recorded before Whirr stored widths.
    public let widthMHz: Int?
}

/// One change in the channel this Mac's Wi-Fi was on. Usually the router
/// switched channel (automatic modes do this on their own, especially
/// after a restart); on mesh systems it can also be the Mac moving to a
/// different access point. Whirr only states what it saw.
public struct ChannelChange: Equatable, Sendable, Identifiable {
    public let from: LinkPoint
    public let to: LinkPoint
    /// The first minute Whirr saw the new channel.
    public let at: Date
    /// Set when Whirr wasn't watching (or Wi-Fi was off) just before
    /// `at`: the change happened sometime between this and `at`.
    public let notBefore: Date?

    public var id: Date { at }

    public var description: String {
        if from.band != to.band {
            return "Your Mac switched from \(from.band) (channel \(from.channel)) to \(to.band) (channel \(to.channel))."
        }
        if from.channel != to.channel {
            return "Your Mac's Wi-Fi moved from \(from.band) channel \(from.channel) to channel \(to.channel)."
        }
        return "Your Mac's Wi-Fi on \(to.band) channel \(to.channel) changed width from \(from.widthMHz ?? 0) MHz to \(to.widthMHz ?? 0) MHz."
    }
}

/// Derives channel changes from minute history — no extra storage.
public enum ChannelChangeLog {
    /// Changes on `networkId`, newest first.
    public static func changes(_ aggregates: [MinuteAggregate], networkId: String) -> [ChannelChange] {
        var result: [ChannelChange] = []
        var last: (point: LinkPoint, minute: Date)?
        for agg in aggregates.filter({ $0.networkId == networkId }).sorted(by: { $0.minute < $1.minute }) {
            guard let channel = agg.channel, let band = agg.band else { continue }
            let point = LinkPoint(band: band, channel: channel, widthMHz: agg.widthMHz)
            if let previous = last, differs(previous.point, point) {
                let consecutive = agg.minute.timeIntervalSince(previous.minute) <= 60
                result.append(ChannelChange(from: previous.point, to: point, at: agg.minute,
                                            notBefore: consecutive ? nil : previous.minute.addingTimeInterval(60)))
            }
            last = (point, agg.minute)
        }
        return result.reversed()
    }

    /// Widths are compared only when both are known, so old history
    /// without widths never produces an invented change.
    private static func differs(_ a: LinkPoint, _ b: LinkPoint) -> Bool {
        if a.band != b.band || a.channel != b.channel { return true }
        if let wa = a.widthMHz, let wb = b.widthMHz { return wa != wb }
        return false
    }
}
