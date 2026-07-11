import XCTest
@testable import WhirrCore

/// The log persists diagnosis incidents so the Insights charts can
/// visualize them. These tests pin down the retention rules (30 days
/// AND 10k cap) and JSON persistence — the surface that would silently
/// go wrong is retention or partial-write corruption after a crash.
final class IncidentLogTests: XCTestCase {
    private var tmpPath: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhirrIncidentLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tmpPath = dir.appendingPathComponent("incidents.json").path
    }

    override func tearDownWithError() throws {
        let dir = (tmpPath as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: dir)
        try super.tearDownWithError()
    }

    private func makeIncident(
        _ title: String,
        firstSeenAt: Date,
        durationSeconds: Int = 30,
        severity: Severity = .warning,
        culprits: [String] = []
    ) -> DiagnosisIncident {
        DiagnosisIncident(
            title: title,
            peakSeverity: severity,
            firstSeenAt: firstSeenAt,
            lastSeenAt: firstSeenAt.addingTimeInterval(Double(durationSeconds)),
            culprits: culprits
        )
    }

    // MARK: - Basic append + read-back

    func testAppendedIncidentSurfaces() {
        let log = IncidentLog(path: tmpPath)
        let now = Date()
        log.record(makeIncident("A", firstSeenAt: now))
        XCTAssertEqual(log.all().map(\.title), ["A"])
    }

    func testMultipleAppendsPreserveOrder() {
        let log = IncidentLog(path: tmpPath)
        let base = Date()
        log.record(makeIncident("A", firstSeenAt: base))
        log.record(makeIncident("B", firstSeenAt: base.addingTimeInterval(10)))
        log.record(makeIncident("C", firstSeenAt: base.addingTimeInterval(20)))
        XCTAssertEqual(log.all().map(\.title), ["A", "B", "C"])
    }

    // MARK: - Persistence

    func testDataSurvivesReinstantiation() {
        let base = Date()
        let a = IncidentLog(path: tmpPath)
        a.record(makeIncident("A", firstSeenAt: base, culprits: ["Chrome"]))

        // New log instance reading the same file — mirrors app restart.
        let b = IncidentLog(path: tmpPath)
        XCTAssertEqual(b.all().map(\.title), ["A"])
        XCTAssertEqual(b.all().first?.culprits, ["Chrome"])
    }

    // MARK: - Retention

    func testEntriesBeyondRetentionAreDropped() {
        let log = IncidentLog(path: tmpPath, retentionDays: 30, maxEntries: 10_000)
        let now = Date()
        // 60 days old — well past 30-day retention.
        log.record(makeIncident("old", firstSeenAt: now.addingTimeInterval(-60 * 86_400)))
        // Recent — should survive.
        log.record(makeIncident("recent", firstSeenAt: now))
        let titles = log.all().map(\.title)
        XCTAssertTrue(titles.contains("recent"))
        XCTAssertFalse(titles.contains("old"),
                       "Entries older than retention window should be purged on write")
    }

    func testMaxEntriesTrimmedFromOldest() {
        // Small caps for a fast test — the same policy that bites at 10k.
        let log = IncidentLog(path: tmpPath, retentionDays: 30, maxEntries: 3)
        let base = Date()
        for i in 0..<5 {
            log.record(makeIncident("i\(i)", firstSeenAt: base.addingTimeInterval(Double(i))))
        }
        let titles = log.all().map(\.title)
        XCTAssertEqual(titles.count, 3)
        // Older entries are dropped, newest kept.
        XCTAssertEqual(titles, ["i2", "i3", "i4"])
    }

    // MARK: - Query window

    func testIncidentsFilteredByDateWindow() {
        let log = IncidentLog(path: tmpPath)
        let now = Date()
        log.record(makeIncident("recent", firstSeenAt: now))
        log.record(makeIncident("mid",    firstSeenAt: now.addingTimeInterval(-3 * 86_400)))
        log.record(makeIncident("old",    firstSeenAt: now.addingTimeInterval(-15 * 86_400)))

        let lastWeek = log.incidents(from: now.addingTimeInterval(-7 * 86_400), to: now)
        let titles = Set(lastWeek.map(\.title))
        XCTAssertEqual(titles, ["recent", "mid"])
    }
}
