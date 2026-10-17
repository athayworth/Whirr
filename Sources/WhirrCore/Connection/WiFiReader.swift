import CoreWLAN
import Foundation

public protocol WiFiReading: Sendable {
    /// Current association, or nil when Wi-Fi is off / not associated.
    func currentLink() -> WiFiLink?
    /// One active scan. Briefly takes the radio off-channel — only ever
    /// call this from the user-triggered connection test. nil when the
    /// scan failed; never an empty list standing in for a failure.
    func scanNeighbors() -> [NeighborNetwork]?
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

    public func scanNeighbors() -> [NeighborNetwork]? {
        guard let iface = CWWiFiClient.shared().interface(),
              let networks = try? iface.scanForNetworks(withSSID: nil) else { return nil }
        let heard = networks.compactMap { network -> NeighborNetwork? in
            guard let channel = network.wlanChannel else { return nil }
            return NeighborNetwork(channel: channel.channelNumber, band: Self.bandName(channel),
                                   widthMHz: Self.widthMHz(channel), rssi: network.rssiValue)
        }
        // The Mac's own network is always audible while connected, so an
        // empty result means the scan didn't really happen.
        return heard.isEmpty ? nil : heard.sorted { ($0.band, $0.channel, $0.rssi) < ($1.band, $1.channel, $1.rssi) }
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
