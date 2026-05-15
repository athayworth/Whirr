import XCTest
@testable import WhirrCore

final class HistoryBucketTests: XCTestCase {
    private func point(_ secondsAgo: TimeInterval, _ severity: Severity, now: Date) -> TrendPoint {
        TrendPoint(
            capturedAt: now.addingTimeInterval(-secondsAgo),
            memoryPressure: .normal,
            memoryUsedBytes: 0,
            swapUsedBytes: 0,
            loadOneMinute: 0,
            worstSeverity: severity
        )
    }

    func testEmptyHistoryProducesEmptyBuckets() {
        let buckets = HistoryBucket.bucket([], bucketCount: 10, bucketSize: 60, endingAt: Date())
        XCTAssertEqual(buckets.count, 10)
        XCTAssertTrue(buckets.allSatisfy { $0.severity == nil })
    }

    func testRecentPointLandsInLastBucket() {
        let now = Date()
        let buckets = HistoryBucket.bucket(
            [point(5, .critical, now: now)],
            bucketCount: 10,
            bucketSize: 60,
            endingAt: now
        )
        XCTAssertEqual(buckets.last?.severity, .critical)
        XCTAssertTrue(buckets.dropLast().allSatisfy { $0.severity == nil })
    }

    func testOldPointLandsInEarlierBucket() {
        let now = Date()
        // 7 minutes ago should land in bucket 10 - 1 - 7 = bucket 2
        let buckets = HistoryBucket.bucket(
            [point(7 * 60 + 5, .warning, now: now)],
            bucketCount: 10,
            bucketSize: 60,
            endingAt: now
        )
        XCTAssertEqual(buckets[2].severity, .warning)
    }

    func testBucketTakesWorstSeverityInRange() {
        let now = Date()
        // Three points within the same minute — bucket should reflect critical.
        let buckets = HistoryBucket.bucket(
            [
                point(5, .ok, now: now),
                point(20, .warning, now: now),
                point(40, .critical, now: now)
            ],
            bucketCount: 1,
            bucketSize: 60,
            endingAt: now
        )
        XCTAssertEqual(buckets[0].severity, .critical)
    }

    func testPointsBeyondWindowAreDropped() {
        let now = Date()
        // 11 minutes ago is outside a 10-minute window.
        let buckets = HistoryBucket.bucket(
            [point(11 * 60, .critical, now: now)],
            bucketCount: 10,
            bucketSize: 60,
            endingAt: now
        )
        XCTAssertTrue(buckets.allSatisfy { $0.severity == nil })
    }
}
