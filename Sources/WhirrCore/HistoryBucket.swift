import Foundation

/// A single column in the menu bar's history strip — represents the worst
/// severity seen during a time bucket. `severity == nil` means no data for
/// that bucket (typically because the daemon hadn't been running yet).
public struct HistoryBucket: Identifiable, Sendable, Hashable {
    /// Index 0 is the oldest bucket; the last index is "now."
    public let id: Int
    public let severity: Severity?

    public init(id: Int, severity: Severity?) {
        self.id = id
        self.severity = severity
    }

    /// Bucket `points` into `bucketCount` equal-time buckets of `bucketSize`
    /// seconds each, ending at `endingAt`. Each bucket takes the worst
    /// severity observed within its time range. Older points and points in
    /// the future are dropped.
    public static func bucket(
        _ points: [TrendPoint],
        bucketCount: Int,
        bucketSize: TimeInterval,
        endingAt: Date
    ) -> [HistoryBucket] {
        var worstByBucket: [Int: Severity] = [:]
        let totalSpan = Double(bucketCount) * bucketSize

        for point in points {
            let secondsAgo = endingAt.timeIntervalSince(point.capturedAt)
            guard secondsAgo >= 0, secondsAgo < totalSpan else { continue }
            // The bucket index counts forward in time, so the most recent
            // bucket is bucketCount - 1 and the oldest is 0.
            let bucketIdx = bucketCount - 1 - Int(secondsAgo / bucketSize)
            guard bucketIdx >= 0, bucketIdx < bucketCount else { continue }

            let existing = worstByBucket[bucketIdx]
            if existing == nil || point.worstSeverity > existing! {
                worstByBucket[bucketIdx] = point.worstSeverity
            }
        }

        return (0..<bucketCount).map { idx in
            HistoryBucket(id: idx, severity: worstByBucket[idx])
        }
    }
}
