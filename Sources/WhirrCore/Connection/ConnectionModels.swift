import Foundation

/// Which leg of the connection a ping measured. Comparing the two is how
/// Whirr tells "your Wi-Fi" apart from "your internet provider".
public enum Hop: String, Codable, Sendable, CaseIterable {
    /// Mac → home router. Problems here are inside the home (Wi-Fi).
    case gateway
    /// Mac → a stable internet host. Includes the gateway leg.
    case internet
}

public struct PingSample: Codable, Sendable, Equatable {
    public let at: Date
    public let hop: Hop
    /// Round-trip time in milliseconds; nil means the ping timed out.
    public let rttMs: Double?

    public init(at: Date, hop: Hop, rttMs: Double?) {
        self.at = at
        self.hop = hop
        self.rttMs = rttMs
    }
}

/// Current Wi-Fi association as read from CoreWLAN. No SSID: reading it
/// requires Location permission and Whirr doesn't need it.
public struct WiFiLink: Codable, Sendable, Equatable {
    public let rssi: Int
    public let noise: Int
    public let channel: Int
    public let band: String
    public let widthMHz: Int
    public let txRateMbps: Double
    public let phyMode: String

    public init(rssi: Int, noise: Int, channel: Int, band: String, widthMHz: Int, txRateMbps: Double, phyMode: String) {
        self.rssi = rssi
        self.noise = noise
        self.channel = channel
        self.band = band
        self.widthMHz = widthMHz
        self.txRateMbps = txRateMbps
        self.phyMode = phyMode
    }

    /// Signal-to-noise ratio in dB — how far the signal stands above the
    /// background hiss. Below ~20 dB, connections get unreliable.
    public var snr: Int { rssi - noise }

    public enum Quality: Sendable, Equatable { case strong, ok, weak }

    /// Uses the same "weak" line as the weak-signal finding, so the
    /// Overview tile and the findings never disagree.
    public var quality: Quality {
        let config = ConnectionRuleConfig()
        if rssi < config.weakRssi || snr < config.weakSnr { return .weak }
        if rssi >= -60 && snr >= 25 { return .strong }
        return .ok
    }

    /// Human band label. CoreWLAN reports the band directly; the channel
    /// number fallback covers interfaces that don't.
    public static func bandName(channel: Int, rawBand: String?) -> String {
        if let rawBand { return rawBand }
        return channel <= 14 ? "2.4 GHz" : "5 GHz"
    }
}

/// One Wi-Fi network heard during a scan. macOS only reveals network
/// names with Location access, which Whirr asks for only if the user opts
/// in; then each entry is marked as yours or not, and the name is dropped.
public struct NeighborNetwork: Codable, Sendable, Equatable {
    public let channel: Int
    public let band: String
    public let widthMHz: Int
    public let rssi: Int
    /// Whether this is the Mac's own network (same name). nil when macOS
    /// withheld names (no Location access). The name itself is never kept.
    public let isYours: Bool?

    public init(channel: Int, band: String, widthMHz: Int, rssi: Int, isYours: Bool? = nil) {
        self.channel = channel
        self.band = band
        self.widthMHz = widthMHz
        self.rssi = rssi
        self.isYours = isYours
    }

    public var block: ChannelBlock { WiFiSpectrum.occupied(band: band, channel: channel, widthMHz: widthMHz) }
}

public struct GatewayInfo: Sendable, Equatable {
    public let ip: String
    /// Router hardware address from the ARP table. Stable per physical
    /// router, so it identifies "home" without needing the SSID.
    public let mac: String?

    public init(ip: String, mac: String?) {
        self.ip = ip
        self.mac = mac
    }

    public var networkId: String { mac ?? ip }
}
