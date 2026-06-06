import SwiftUI
import WhirrCore

/// Filled-area CPU sparkline for a single Docker container. Newest sample
/// on the right, axis clipped at the higher of 100% or the observed peak
/// so a 50% spike doesn't get flattened by an outlier (e.g., a one-tick
/// 300% burn) while still being readable when the container is steady.
///
/// Visually deliberate: the system history strip above is a discrete
/// severity-bucket ribbon; this is a continuous metric line. Different
/// shapes for different semantics.
struct ContainerSparkline: View {
    let history: [DockerHistoryPoint]
    /// Approximate seconds covered by the data when the view is at full
    /// width. Surfaced in the caption so the reader knows whether the
    /// strip represents "the last 30 seconds" (fresh container) vs. "the
    /// last 30 minutes."
    let coveredSeconds: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("CPU over last \(coveredLabel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(rangeLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            sparkline
                .frame(height: 36)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var sparkline: some View {
        Canvas { ctx, size in
            guard history.count >= 2 else {
                // Single point: draw a flat baseline so the row doesn't
                // look broken on the first tick. Future ticks fill it in.
                return
            }

            // y = 0 maps to bottom, y = max maps to top. Floor at 100% so
            // a quiet container's noise around 1-2% isn't magnified into
            // a panic shape; raise above 100% when the container ran
            // multi-core (docker-style values can exceed 100%).
            let observed = history.map(\.cpuPercent).max() ?? 0
            let yMax = max(100.0, observed)

            // Compute path through all points first; reuse for both
            // stroke and fill.
            var stroke = Path()
            for (index, point) in history.enumerated() {
                let xFrac = CGFloat(index) / CGFloat(max(1, history.count - 1))
                let yFrac = 1.0 - CGFloat(point.cpuPercent / yMax)
                let p = CGPoint(x: xFrac * size.width, y: yFrac * size.height)
                if index == 0 { stroke.move(to: p) } else { stroke.addLine(to: p) }
            }

            // Filled area under the curve — softer blue, lower visual
            // weight than the stroke. Sits inside the same path; we
            // extend it down to the baseline and close.
            var fill = stroke
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(.blue.opacity(0.18)))
            ctx.stroke(stroke, with: .color(.blue), lineWidth: 1.5)
        }
    }

    private var coveredLabel: String {
        if coveredSeconds >= 120 { return "\(coveredSeconds / 60) min" }
        return "\(coveredSeconds) s"
    }

    private var rangeLabel: String {
        let values = history.map(\.cpuPercent)
        guard let lo = values.min(), let hi = values.max() else { return "" }
        let loStr = lo >= 10 ? String(format: "%.0f", lo) : String(format: "%.1f", lo)
        let hiStr = hi >= 10 ? String(format: "%.0f", hi) : String(format: "%.1f", hi)
        return "\(loStr)% — \(hiStr)%"
    }

    private var accessibilityLabel: String {
        guard let last = history.last?.cpuPercent,
              let peak = history.map(\.cpuPercent).max(),
              let trough = history.map(\.cpuPercent).min() else {
            return "CPU sparkline, no data"
        }
        return String(
            format: "CPU history over %@: current %.0f percent, peak %.0f, low %.0f",
            coveredLabel, last, peak, trough
        )
    }
}
