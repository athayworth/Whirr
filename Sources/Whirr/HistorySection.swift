import SwiftUI
import WhirrCore

/// Last-30-minutes strip of severity buckets. Owns the bucketing call so
/// MenuBarView doesn't have to thread the bucket array through.
struct HistorySection: View {
    let history: [TrendPoint]

    private var buckets: [HistoryBucket] {
        HistoryBucket.bucket(history, bucketCount: 30, bucketSize: 60, endingAt: Date())
    }

    var body: some View {
        let buckets = self.buckets
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Last 30 minutes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(summary(buckets))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 1) {
                ForEach(buckets) { bucket in
                    Rectangle()
                        .fill(color(for: bucket.severity))
                        .frame(height: 10)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(accessibilitySummary(buckets))
        }
    }

    private func color(for severity: Severity?) -> Color {
        guard let severity else { return Color.gray.opacity(0.15) }
        switch severity {
        case .ok:       return .green.opacity(0.6)
        case .warning:  return .yellow
        case .critical: return .red
        }
    }

    private func summary(_ buckets: [HistoryBucket]) -> String {
        let withData = buckets.filter { $0.severity != nil }
        guard !withData.isEmpty else { return "" }
        let criticalCount = withData.filter { $0.severity == .critical }.count
        if criticalCount > 0 {
            return "critical for \(criticalCount) of last \(withData.count) min"
        }
        let warningCount = withData.filter { $0.severity == .warning }.count
        if warningCount > 0 {
            return "warning for \(warningCount) of last \(withData.count) min"
        }
        return "healthy"
    }

    /// VoiceOver-friendly summary of the strip — the colored rectangles are
    /// meaningless without sight, so describe the trend in words.
    private func accessibilitySummary(_ buckets: [HistoryBucket]) -> String {
        let withData = buckets.filter { $0.severity != nil }
        guard !withData.isEmpty else { return "History: no data yet." }
        let criticalCount = withData.filter { $0.severity == .critical }.count
        let warningCount = withData.filter { $0.severity == .warning }.count
        let healthyCount = withData.count - criticalCount - warningCount
        return "History over \(withData.count) minutes: "
            + "\(criticalCount) critical, \(warningCount) warning, \(healthyCount) healthy."
    }
}
