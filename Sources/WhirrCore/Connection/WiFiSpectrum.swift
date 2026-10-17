import Foundation

/// The stretch of airwaves one Wi-Fi network actually uses. A network
/// "on channel 157" at 80 MHz really occupies channels 149–161; anything
/// else on that stretch shares airtime with it.
public struct ChannelBlock: Hashable, Sendable {
    public let band: String
    /// The 20 MHz channels covered. For 2.4 GHz this is just the primary
    /// channel — 2.4 GHz channels overlap their neighbours, which the
    /// frequency range below accounts for.
    public let channels: ClosedRange<Int>
    public let widthMHz: Int
    /// Occupied frequency range, used for overlap.
    let lowMHz: Int
    let highMHz: Int

    /// "channels 149–161" or "channel 36".
    public var label: String {
        channels.count > 1
            ? "channels \(channels.lowerBound)–\(channels.upperBound)"
            : "channel \(channels.lowerBound)"
    }

    /// 5 GHz channels 52–144 are shared with weather and airport radar.
    /// Routers there must move off when they detect radar, which drops
    /// Wi-Fi for about a minute.
    public var isRadarShared: Bool {
        band == "5 GHz" && channels.overlaps(52...144)
    }
}

public enum WiFiSpectrum {
    /// The block a network on `channel` at `widthMHz` occupies. An unknown
    /// width (0) is treated as 20 MHz — the narrowest — so crowding is
    /// never overstated.
    public static func occupied(band: String, channel: Int, widthMHz: Int) -> ChannelBlock {
        let width = [20, 40, 80, 160].contains(widthMHz) ? widthMHz : 20
        switch band {
        case "2.4 GHz":
            let center = channel == 14 ? 2484 : 2407 + 5 * channel
            // CoreWLAN doesn't say which side a 2.4 GHz 40 MHz network
            // extends to, so cover both rather than guess.
            let half = width >= 40 ? 30 : 10
            return ChannelBlock(band: band, channels: channel...channel, widthMHz: width,
                                lowMHz: center - half, highMHz: center + half)
        case "6 GHz":
            return aligned(band: band, channel: channel, width: width, base: 1, groupEnd: 233, baseMHz: 5950)
        default:
            let (base, end): (Int, Int) = channel >= 149 ? (149, 177) : channel >= 100 ? (100, 144) : (36, 64)
            guard channel >= base else {
                return aligned(band: band, channel: channel, width: 20, base: channel, groupEnd: channel, baseMHz: 5000)
            }
            return aligned(band: band, channel: channel, width: width, base: base, groupEnd: end, baseMHz: 5000)
        }
    }

    /// Standard alignment: blocks of `width / 20` channels counted from the
    /// group's first channel. A block that would run past the group's end
    /// (e.g. 160 MHz at 132) falls back to the next narrower width.
    private static func aligned(band: String, channel: Int, width: Int, base: Int, groupEnd: Int, baseMHz: Int) -> ChannelBlock {
        let span = width / 20
        let index = (channel - base) / 4
        let first = base + (index / span) * span * 4
        let last = first + (span - 1) * 4
        if last > groupEnd && width > 20 {
            return aligned(band: band, channel: channel, width: width / 2, base: base, groupEnd: groupEnd, baseMHz: baseMHz)
        }
        return ChannelBlock(band: band, channels: first...last, widthMHz: width,
                            lowMHz: baseMHz + 5 * first - 10, highMHz: baseMHz + 5 * last + 10)
    }

    /// Whether two networks share any airwaves.
    public static func overlaps(_ a: ChannelBlock, _ b: ChannelBlock) -> Bool {
        a.band == b.band && a.lowMHz < b.highMHz && b.lowMHz < a.highMHz
    }

    /// Every block of `widthMHz` a router in `band` could use — what the
    /// crowding row compares when suggesting a quieter stretch.
    public static func candidateBlocks(band: String, widthMHz: Int) -> [ChannelBlock] {
        let primaries: [Int]
        switch (band, widthMHz) {
        case ("2.4 GHz", _): primaries = [1, 6, 11]
        case ("5 GHz", 160): primaries = [36, 100]
        case ("5 GHz", 80): primaries = [36, 52, 100, 116, 132, 149]
        case ("5 GHz", 40): primaries = [36, 44, 52, 60, 100, 108, 116, 124, 132, 140, 149, 157]
        case ("5 GHz", _): primaries = Array(stride(from: 36, through: 64, by: 4))
            + Array(stride(from: 100, through: 144, by: 4)) + Array(stride(from: 149, through: 165, by: 4))
        default: primaries = []  // 6 GHz: too new to suggest channels for yet
        }
        let width = band == "2.4 GHz" ? 20 : widthMHz
        return primaries.map { occupied(band: band, channel: $0, widthMHz: width) }
    }
}
