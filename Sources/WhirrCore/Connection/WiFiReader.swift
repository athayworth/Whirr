import CoreWLAN
import Foundation

public protocol WiFiReading: Sendable {
    /// Current association, or nil when Wi-Fi is off / not associated.
    func currentLink() -> WiFiLink?
    /// One active scan. Briefly takes the radio off-channel — only ever
    /// call this from the user-triggered connection test.
    func scanNeighbors() -> [NeighborCount]
}

public struct CoreWLANReader: WiFiReading {
    public init() {}

    public func currentLink() -> WiFiLink? {
        guard let iface = CWWiFiClient.shared().interface(),
              iface.powerOn(),
              let channel = iface.wlanChannel() else { return nil }
        let rssi = iface.rssiValue()
        // rssi 0 means "not associated" on macOS.
        guard rssi != 0 else { return nil }
        return WiFiLink(
            rssi: rssi,
            noise: iface.noiseMeasurement(),
            channel: channel.channelNumber,
            band: Self.bandName(channel),
            widthMHz: Self.widthMHz(channel),
            txRateMbps: iface.transmitRate(),
            phyMode: Self.phyName(iface.activePHYMode())
        )
    }

    public func scanNeighbors() -> [NeighborCount] {
        guard let iface = CWWiFiClient.shared().interface(),
              let networks = try? iface.scanForNetworks(withSSID: nil) else { return [] }
        var counts: [String: (channel: Int, band: String, count: Int)] = [:]
        for network in networks {
            guard let channel = network.wlanChannel else { continue }
            let band = Self.bandName(channel)
            let key = "\(band)-\(channel.channelNumber)"
            counts[key, default: (channel.channelNumber, band, 0)].count += 1
        }
        return counts.values
            .map { NeighborCount(channel: $0.channel, band: $0.band, count: $0.count) }
            .sorted { ($0.band, $0.channel) < ($1.band, $1.channel) }
    }

    static func bandName(_ channel: CWChannel) -> String {
        switch channel.channelBand {
        case .band2GHz: return "2.4 GHz"
        case .band5GHz: return "5 GHz"
        case .band6GHz: return "6 GHz"
        default: return WiFiLink.bandName(channel: channel.channelNumber, rawBand: nil)
        }
    }

    static func widthMHz(_ channel: CWChannel) -> Int {
        switch channel.channelWidth {
        case .width20MHz: return 20
        case .width40MHz: return 40
        case .width80MHz: return 80
        case .width160MHz: return 160
        default: return 0
        }
    }

    static func phyName(_ mode: CWPHYMode) -> String {
        switch mode {
        case .mode11a: return "802.11a"
        case .mode11b: return "802.11b"
        case .mode11g: return "802.11g"
        case .mode11n: return "802.11n"
        case .mode11ac: return "802.11ac"
        case .mode11ax: return "802.11ax"
        default: return "unknown"
        }
    }
}
