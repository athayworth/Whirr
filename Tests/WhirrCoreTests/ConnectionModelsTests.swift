import XCTest
@testable import WhirrCore

final class ConnectionModelsTests: XCTestCase {
    func testSNRIsSignalMinusNoise() {
        let link = WiFiLink(rssi: -58, noise: -88, channel: 36, band: "5 GHz", widthMHz: 80, txRateMbps: 576, phyMode: "802.11ax")
        XCTAssertEqual(link.snr, 30)
    }

    func testNetworkIdPrefersGatewayMAC() {
        XCTAssertEqual(GatewayInfo(ip: "192.168.1.1", mac: "aa:bb:cc:dd:ee:ff").networkId, "aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(GatewayInfo(ip: "192.168.1.1", mac: nil).networkId, "192.168.1.1")
    }

    func testBandFromChannel() {
        XCTAssertEqual(WiFiLink.bandName(channel: 6, rawBand: nil), "2.4 GHz")
        XCTAssertEqual(WiFiLink.bandName(channel: 149, rawBand: nil), "5 GHz")
    }

    func testICMPChecksumMatchesRFC1071Example() {
        // Echo request header with zero checksum, id 0x1234, seq 1.
        let bytes: [UInt8] = [8, 0, 0, 0, 0x12, 0x34, 0x00, 0x01]
        let sum = ICMPPinger.checksum(bytes)
        // Verifying: inserting the checksum makes the whole thing sum to 0.
        var withSum = bytes
        withSum[2] = UInt8(sum >> 8); withSum[3] = UInt8(sum & 0xff)
        XCTAssertEqual(ICMPPinger.checksum(withSum), 0)
    }
}
