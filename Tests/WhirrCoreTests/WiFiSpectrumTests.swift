import XCTest
@testable import WhirrCore

final class WiFiSpectrumTests: XCTestCase {
    private func block(_ band: String, _ channel: Int, _ width: Int) -> ChannelBlock {
        WiFiSpectrum.occupied(band: band, channel: channel, widthMHz: width)
    }

    func test80MHzBlocksFollowStandardAlignment() {
        XCTAssertEqual(block("5 GHz", 36, 80).channels, 36...48)
        XCTAssertEqual(block("5 GHz", 40, 80).channels, 36...48)
        XCTAssertEqual(block("5 GHz", 48, 80).channels, 36...48)
        XCTAssertEqual(block("5 GHz", 52, 80).channels, 52...64)
        XCTAssertEqual(block("5 GHz", 100, 80).channels, 100...112)
        XCTAssertEqual(block("5 GHz", 120, 80).channels, 116...128)
        XCTAssertEqual(block("5 GHz", 144, 80).channels, 132...144)
        XCTAssertEqual(block("5 GHz", 149, 80).channels, 149...161)
        XCTAssertEqual(block("5 GHz", 157, 80).channels, 149...161)
    }

    func test40And160MHzBlocks() {
        XCTAssertEqual(block("5 GHz", 40, 40).channels, 36...40)
        XCTAssertEqual(block("5 GHz", 44, 40).channels, 44...48)
        XCTAssertEqual(block("5 GHz", 157, 40).channels, 157...161)
        XCTAssertEqual(block("5 GHz", 44, 160).channels, 36...64)
        XCTAssertEqual(block("5 GHz", 104, 160).channels, 100...128)
    }

    func test20MHzAndUnknownWidthCoverOnlyThePrimaryChannel() {
        XCTAssertEqual(block("5 GHz", 36, 20).channels, 36...36)
        // Unknown width: assume the narrowest, so crowding is never overstated.
        XCTAssertEqual(block("5 GHz", 44, 0).channels, 44...44)
        XCTAssertEqual(block("5 GHz", 44, 0).widthMHz, 20)
    }

    func testThe40MHzNetworkOn40OverlapsAn80MHzNetworkOn36() {
        // The real case that fooled Whirr: "channel 40 is empty" while
        // 80 MHz networks on 36 and 44 covered it.
        let mine = block("5 GHz", 40, 80)
        XCTAssertTrue(WiFiSpectrum.overlaps(mine, block("5 GHz", 36, 80)))
        XCTAssertTrue(WiFiSpectrum.overlaps(mine, block("5 GHz", 44, 20)))
        XCTAssertFalse(WiFiSpectrum.overlaps(mine, block("5 GHz", 149, 80)))
        XCTAssertFalse(WiFiSpectrum.overlaps(mine, block("5 GHz", 52, 80)))
    }

    func testAdjacent20MHzChannelsDoNotOverlap() {
        XCTAssertFalse(WiFiSpectrum.overlaps(block("5 GHz", 36, 20), block("5 GHz", 40, 20)))
    }

    func testDifferentBandsNeverOverlap() {
        XCTAssertFalse(WiFiSpectrum.overlaps(block("5 GHz", 36, 80), block("6 GHz", 37, 80)))
        XCTAssertFalse(WiFiSpectrum.overlaps(block("2.4 GHz", 6, 20), block("5 GHz", 36, 20)))
    }

    func test24GHzChannels1And6And11DoNotOverlapButNeighborsDo() {
        XCTAssertFalse(WiFiSpectrum.overlaps(block("2.4 GHz", 1, 20), block("2.4 GHz", 6, 20)))
        XCTAssertFalse(WiFiSpectrum.overlaps(block("2.4 GHz", 6, 20), block("2.4 GHz", 11, 20)))
        XCTAssertTrue(WiFiSpectrum.overlaps(block("2.4 GHz", 1, 20), block("2.4 GHz", 3, 20)))
        XCTAssertTrue(WiFiSpectrum.overlaps(block("2.4 GHz", 8, 20), block("2.4 GHz", 11, 20)))
    }

    func test24GHz40MHzIsTreatedAsCoveringBothSides() {
        // CoreWLAN doesn't say which side the extra 20 MHz is on.
        XCTAssertTrue(WiFiSpectrum.overlaps(block("2.4 GHz", 6, 40), block("2.4 GHz", 1, 20)))
        XCTAssertTrue(WiFiSpectrum.overlaps(block("2.4 GHz", 6, 40), block("2.4 GHz", 11, 20)))
    }

    func test6GHzBlocksAlignFromChannel1() {
        XCTAssertEqual(block("6 GHz", 5, 80).channels, 1...13)
        XCTAssertEqual(block("6 GHz", 37, 80).channels, 33...45)
        XCTAssertTrue(WiFiSpectrum.overlaps(block("6 GHz", 5, 80), block("6 GHz", 9, 20)))
    }

    func testRadarSharedChannels() {
        XCTAssertFalse(block("5 GHz", 36, 80).isRadarShared)
        XCTAssertTrue(block("5 GHz", 52, 80).isRadarShared)
        XCTAssertTrue(block("5 GHz", 100, 80).isRadarShared)
        XCTAssertTrue(block("5 GHz", 144, 20).isRadarShared)
        XCTAssertFalse(block("5 GHz", 149, 80).isRadarShared)
        XCTAssertTrue(block("5 GHz", 36, 160).isRadarShared) // 36–64 includes 52–64
        XCTAssertFalse(block("2.4 GHz", 6, 20).isRadarShared)
    }

    func testLabels() {
        XCTAssertEqual(block("5 GHz", 157, 80).label, "channels 149–161")
        XCTAssertEqual(block("5 GHz", 36, 20).label, "channel 36")
        XCTAssertEqual(block("2.4 GHz", 6, 20).label, "channel 6")
    }

    func testCandidateBlocksAtAWidth() {
        XCTAssertEqual(WiFiSpectrum.candidateBlocks(band: "5 GHz", widthMHz: 80).map(\.channels.lowerBound),
                       [36, 52, 100, 116, 132, 149])
        XCTAssertEqual(WiFiSpectrum.candidateBlocks(band: "2.4 GHz", widthMHz: 20).map(\.channels.lowerBound),
                       [1, 6, 11])
        XCTAssertEqual(WiFiSpectrum.candidateBlocks(band: "5 GHz", widthMHz: 160).map(\.channels.lowerBound),
                       [36, 100])
    }

    func testBlocksAreHashableIdentityForGrouping() {
        XCTAssertEqual(block("5 GHz", 149, 80), block("5 GHz", 157, 80))
        XCTAssertNotEqual(block("5 GHz", 149, 80), block("5 GHz", 149, 40))
    }
}

final class OwnNetworkMatchingTests: XCTestCase {
    func testOwnershipNeedsOurOwnNameFirst() {
        XCTAssertNil(CoreWLANReader.isYours(network: "Neighbor", mine: nil))
        XCTAssertNil(CoreWLANReader.isYours(network: nil, mine: nil))
        XCTAssertEqual(CoreWLANReader.isYours(network: "Home", mine: "Home"), true)
        XCTAssertEqual(CoreWLANReader.isYours(network: "Neighbor", mine: "Home"), false)
        XCTAssertEqual(CoreWLANReader.isYours(network: nil, mine: "Home"), false, "hidden network")
    }
}
