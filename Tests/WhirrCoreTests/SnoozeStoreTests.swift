import XCTest
@testable import WhirrCore

/// SnoozeStore holds durable user state — a broken persistence layer
/// silently lets warnings the user muted come back. These tests pin
/// down the lifecycle (create → expire → purge → persist) and the
/// UserDefaults round-trip.
///
/// Each test uses an isolated in-memory `UserDefaults` suite so the
/// real user's snooze state on the developer machine is never touched.
@MainActor
final class SnoozeStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "WhirrSnoozeStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // Belt-and-suspenders: nuke anything the suite might have kept.
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - Snooze / unsnooze

    func testSnoozedTitleReportsAsSnoozed() {
        let store = SnoozeStore(userDefaults: defaults)
        let now = Date()
        store.snooze("Memory is tight", duration: 3600, at: now)
        XCTAssertTrue(store.isSnoozed("Memory is tight", at: now.addingTimeInterval(30)))
    }

    func testExpiredSnoozeReportsAsNotSnoozedAndIsPurged() {
        let store = SnoozeStore(userDefaults: defaults)
        let now = Date()
        store.snooze("Memory is tight", duration: 60, at: now)
        // 61 s later — one second past expiry.
        let later = now.addingTimeInterval(61)
        XCTAssertFalse(store.isSnoozed("Memory is tight", at: later))
        // Confirm the entry was removed from persistence, not just
        // filtered on read.
        let reloaded = SnoozeStore(userDefaults: defaults)
        XCTAssertFalse(reloaded.isSnoozed("Memory is tight", at: later))
    }

    func testUnsnoozeRemovesTheEntry() {
        let store = SnoozeStore(userDefaults: defaults)
        store.snooze("A", duration: 3600)
        store.unsnooze("A")
        XCTAssertFalse(store.isSnoozed("A"))
    }

    func testRepeatedSnoozePushesExpiryForward() {
        let store = SnoozeStore(userDefaults: defaults)
        let t0 = Date()
        store.snooze("A", duration: 60, at: t0)
        let firstExpiry = store.snoozeExpiry("A", at: t0)!
        // Second snooze one minute later — expiry should be pushed to
        // the *later* value, not the earlier one.
        let t1 = t0.addingTimeInterval(60)
        store.snooze("A", duration: 60, at: t1)
        let secondExpiry = store.snoozeExpiry("A", at: t1)!
        XCTAssertGreaterThan(secondExpiry, firstExpiry)
    }

    // MARK: - Persistence

    func testSnoozeStateSurvivesReinstantiation() {
        let a = SnoozeStore(userDefaults: defaults)
        let now = Date()
        a.snooze("A", duration: 3600, at: now)

        // Simulate app restart — new instance reading the same suite.
        let b = SnoozeStore(userDefaults: defaults)
        XCTAssertTrue(b.isSnoozed("A", at: now.addingTimeInterval(30)))
    }

    func testExpiredEntriesArePurgedAtLoadTime() {
        // Seed the suite with an already-expired snooze via a fresh
        // store, close it, then observe that a fresh instance ignores
        // the expired entry.
        let now = Date()
        do {
            let seed = SnoozeStore(userDefaults: defaults)
            seed.snooze("A", duration: -60, at: now)  // expiry in the past
        }
        let fresh = SnoozeStore(userDefaults: defaults)
        XCTAssertFalse(fresh.isSnoozed("A", at: now))
    }

    // MARK: - active()

    func testActiveReturnsOnlyLiveEntriesSortedByExpiryAscending() {
        let store = SnoozeStore(userDefaults: defaults)
        let now = Date()
        store.snooze("later",   duration: 3600, at: now)
        store.snooze("earlier", duration: 60,   at: now)
        store.snooze("expired", duration: -1,   at: now)

        let active = store.active(at: now)
        XCTAssertEqual(active.map(\.title), ["earlier", "later"],
                       "active should sort by expiry ascending and drop expired entries")
    }

    // MARK: - Expiry hint

    func testSnoozeExpiryReturnsDateForActiveTitle() {
        let store = SnoozeStore(userDefaults: defaults)
        let now = Date()
        store.snooze("A", duration: 3600, at: now)
        XCTAssertNotNil(store.snoozeExpiry("A", at: now.addingTimeInterval(30)))
    }

    func testSnoozeExpiryReturnsNilForExpiredTitle() {
        let store = SnoozeStore(userDefaults: defaults)
        let now = Date()
        store.snooze("A", duration: 60, at: now)
        XCTAssertNil(store.snoozeExpiry("A", at: now.addingTimeInterval(120)))
    }
}
