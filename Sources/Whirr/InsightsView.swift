import SwiftUI
import Charts
import WhirrCore

/// Insights tab in Settings — visualizes the persisted incident log so
/// the user can see patterns (which rules fire most, when, and which
/// processes are the usual suspects) rather than reading the menu bar
/// in isolation each time.
///
/// **Data source**: `IncidentLog` at `~/Library/Application
/// Support/Whirr/incidents.json`, populated by `SamplingPipeline` on
/// every diagnosis-closes transition. Nothing is emitted while
/// diagnoses are actively firing — only when they clear — so the log
/// is a record of *closed* incidents, not a live feed.
struct InsightsView: View {
    let log: IncidentLog

    /// User's chosen window (7/30 days). Bigger windows are harder to
    /// read at a glance; smaller windows can miss patterns. 7 is the
    /// default because most users will check in every few days.
    @AppStorage("preferences.insightsWindowDays") private var windowDays: Int = 7

    /// Refresh trigger — bumped when the view (re)appears so we
    /// re-read the log without holding a reference to a mutable state.
    @State private var refreshTick: Int = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if incidents.isEmpty {
                    emptyState
                } else {
                    if !streaks.isEmpty {
                        streakCallout
                    }
                    incidentsPerDayChart
                    timeInSeverityChart
                    topOffendersChart
                    summaryFooter
                    recentIncidentsList
                }
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 500)
        .onAppear { refreshTick &+= 1 }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Insights")
                    .font(.title2).bold()
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Window", selection: $windowDays) {
                Text("Last 7 days").tag(7)
                Text("Last 30 days").tag(30)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    private var headerSubtitle: String {
        let count = incidents.count
        guard count > 0 else { return "No incidents recorded yet." }
        let label = count == 1 ? "1 incident" : "\(count) incidents"
        return "\(label) in the last \(windowDays) days."
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No incidents yet.")
                .font(.callout).bold()
            Text("Whirr records each diagnosis that fires and clears. Come back after a day or two of running for patterns.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Chart 1: incidents per day, stacked by rule title

    private var incidentsPerDayChart: some View {
        chartCard(
            title: "Incidents per day",
            explanation: "How many times each rule fired and cleared each day. Tall bars = your machine had a rough day; consistent colors day-to-day = you know what to fix."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Chart(dailyIncidentBuckets) { bucket in
                    BarMark(
                        x: .value("Day", bucket.day, unit: .day),
                        y: .value("Count", bucket.count)
                    )
                    .foregroundStyle(by: .value("Rule", bucket.title))
                }
                // Hide the auto-legend. With a dozen unique rule titles
                // it explodes vertically and pushes into neighboring
                // cards. We render a bounded custom legend below that
                // caps at N + "Other" so total height stays predictable.
                .chartLegend(.hidden)
                .frame(height: 200)

                compactLegend(for: dailyIncidentBuckets)
            }
        }
    }

    /// Small manual legend for the incidents-per-day chart. Wraps into
    /// multiple rows via LazyVGrid, so a handful of long titles never
    /// blows out the vertical footprint.
    private func compactLegend(for buckets: [DailyBucket]) -> some View {
        var seen: Set<String> = []
        var ordered: [String] = []
        for bucket in buckets where !seen.contains(bucket.title) {
            seen.insert(bucket.title)
            ordered.append(bucket.title)
        }
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 140), spacing: 6, alignment: .leading)],
            alignment: .leading,
            spacing: 4
        ) {
            ForEach(ordered, id: \.self) { title in
                HStack(spacing: 4) {
                    Circle()
                        .fill(paletteColor(for: title))
                        .frame(width: 8, height: 8)
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.3), in: Capsule())
            }
        }
    }

    /// Deterministic per-title color that roughly mirrors what Charts
    /// picks for `.foregroundStyle(by:)`. Not pixel-perfect against the
    /// chart's own palette, but visually distinguishes chips from each
    /// other and stays stable across renders.
    private func paletteColor(for title: String) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .red, .purple, .teal, .pink, .yellow, .mint, .indigo, .brown, .cyan]
        let idx = abs(title.hashValue) % palette.count
        return palette[idx]
    }

    // MARK: - Chart 2: hours in each severity per day

    private var timeInSeverityChart: some View {
        chartCard(
            title: "Time in each severity",
            explanation: "How many hours per day at least one critical / warning diagnosis was active. Bars near zero = a good day; bars pushing 24 = something's been red all day."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Chart(dailySeverityBuckets) { bucket in
                    BarMark(
                        x: .value("Day", bucket.day, unit: .day),
                        y: .value("Hours", bucket.hours)
                    )
                    .foregroundStyle(by: .value("Severity", bucket.severity.label))
                }
                .chartForegroundStyleScale([
                    "Critical": Color.red,
                    "Warning": Color.orange,
                    "OK": Color.blue
                ])
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisValueLabel {
                            if let hours = value.as(Double.self) {
                                Text("\(Int(hours))h")
                            }
                        }
                        AxisGridLine()
                    }
                }
                // Only 3 possible series here — the auto-legend is
                // small and stable so we let it render inline.
                .chartLegend(position: .bottom, alignment: .center, spacing: 8)
                .frame(height: 220)
            }
        }
    }

    // MARK: - Chart 3: top offenders (culprit frequency)

    private var topOffendersChart: some View {
        chartCard(
            title: "Top offenders",
            explanation: "Which processes appear most in diagnosis details across the window. Recurring names here = candidates for a habit change (close on quit, restart nightly, etc.)."
        ) {
            if topOffenders.isEmpty {
                Text("No process-attributed incidents in this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Custom rendering rather than a Chart: process names
                // can be long, and Swift Charts' default Y-axis label
                // layout crushes them against the bars. A hand-rolled
                // horizontal bar row (label · bar · count) reads
                // cleanly regardless of name length.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(topOffenders) { entry in
                        offenderRow(entry, maxCount: topOffenders.map(\.count).max() ?? 1)
                    }
                }
            }
        }
    }

    private func offenderRow(_ entry: OffenderEntry, maxCount: Int) -> some View {
        HStack(spacing: 8) {
            Text(entry.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 180, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary.opacity(0.4))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.orange)
                        .frame(width: max(4, geo.size.width * CGFloat(entry.count) / CGFloat(maxCount)))
                }
            }
            .frame(height: 12)
            Text("\(entry.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    // MARK: - Streak callout

    private var streakCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(.orange)
                Text("Recurring problems")
                    .font(.headline)
            }
            Text("Diagnoses that fired on multiple recent days. Recurring items are candidates for a habit change (close on quit, restart nightly).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(streaks) { streak in
                HStack(spacing: 8) {
                    Circle()
                        .fill(color(for: streak.peakSeverity))
                        .frame(width: 6, height: 6)
                    Text(streak.title)
                        .font(.callout)
                    Spacer()
                    Text("\(streak.dayCount) days")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("· \(streak.incidentCount) incidents")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Recent incidents (drill-in)

    private var recentIncidentsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent incidents")
                .font(.headline)
            Text("Each closed diagnosis in the window. Latest first.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(sortedRecentIncidents) { inc in
                incidentRow(inc)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func incidentRow(_ inc: DiagnosisIncident) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color(for: inc.peakSeverity))
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(inc.title).font(.callout).bold()
                    Spacer()
                    Text(inc.firstSeenAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 6) {
                    Text("on for \(MenuFormat.duration(seconds: inc.durationSeconds))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !inc.culprits.isEmpty {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(inc.culprits.prefix(3).joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Card wrapper

    @ViewBuilder
    private func chartCard<Content: View>(
        title: String,
        explanation: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Summary footer

    private var summaryFooter: some View {
        HStack(spacing: 12) {
            summaryPill(label: "Worst rule", value: worstRule ?? "—")
            summaryPill(label: "Median incident", value: medianIncidentLabel)
            summaryPill(label: "Longest incident", value: longestIncidentLabel)
        }
    }

    private func summaryPill(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Data derivations
    //
    // Kept as computed properties rather than @State so they refresh
    // whenever `refreshTick` or `windowDays` changes. `refreshTick` is
    // bumped on view appear so opening Settings shows fresh data.

    private var incidents: [DiagnosisIncident] {
        _ = refreshTick  // read to establish a dependency
        let now = Date()
        let cutoff = now.addingTimeInterval(-Double(windowDays * 86_400))
        return log.incidents(from: cutoff, to: now)
    }

    private struct DailyBucket: Identifiable {
        let id = UUID()
        let day: Date
        let title: String
        let count: Int
    }

    /// Number of distinct rule titles kept as first-class series in the
    /// stacked bar chart. Everything past this rolls up into an "Other"
    /// bucket so the legend + palette stay readable. 6 fits a screen's
    /// worth of chips at typical settings width.
    private var maxLegendTitles: Int { 6 }

    private var dailyIncidentBuckets: [DailyBucket] {
        let calendar = Calendar.current

        // Step 1: total incidents by title across the whole window,
        // used to pick which titles are worth showing individually.
        var totalsByTitle: [String: Int] = [:]
        for inc in incidents {
            totalsByTitle[inc.title, default: 0] += 1
        }
        let keepTitles: Set<String> = Set(
            totalsByTitle
                .sorted { $0.value > $1.value }
                .prefix(maxLegendTitles)
                .map(\.key)
        )

        // Step 2: aggregate by (day, keptTitle-or-"Other"). Titles
        // not in the top set collapse into the sentinel so the chart
        // stays at ≤ maxLegendTitles + 1 series.
        var counts: [DayTitleKey: Int] = [:]
        for inc in incidents {
            let day = calendar.startOfDay(for: inc.firstSeenAt)
            let displayTitle = keepTitles.contains(inc.title) ? inc.title : "Other"
            counts[DayTitleKey(day: day, title: displayTitle), default: 0] += 1
        }
        return counts
            .map { key, count in
                DailyBucket(day: key.day, title: key.title, count: count)
            }
            .sorted { $0.day < $1.day }
    }

    private struct DailySeverityBucket: Identifiable {
        let id = UUID()
        let day: Date
        let severity: Severity
        let hours: Double
    }

    /// Group incidents by day and sum duration hours per severity. This
    /// double-counts overlapping incidents (two criticals at the same
    /// time contribute to 2× hours for that day), which is honest for
    /// "how much bad-thing-happening was there" but not for "how much
    /// wall-clock time was bad." The label above the chart makes clear
    /// it's per-incident-hours, not wall-clock.
    private var dailySeverityBuckets: [DailySeverityBucket] {
        let calendar = Calendar.current
        var totals: [DaySeverityKey: Double] = [:]
        for inc in incidents {
            let day = calendar.startOfDay(for: inc.firstSeenAt)
            let hours = Double(inc.durationSeconds) / 3600.0
            totals[DaySeverityKey(day: day, severity: inc.peakSeverity), default: 0] += hours
        }
        return totals.map { key, hours in
            DailySeverityBucket(day: key.day, severity: key.severity, hours: hours)
        }
        .sorted { $0.day < $1.day }
    }

    private struct OffenderEntry: Identifiable {
        let id = UUID()
        let name: String
        let count: Int
    }

    /// Top 5 culprit names across all incidents in the window, sorted
    /// by frequency descending. Culprit strings come from the rules
    /// engine using the friendly-name resolver, so entries here read
    /// like "Google Chrome" rather than raw process names.
    private var topOffenders: [OffenderEntry] {
        var counts: [String: Int] = [:]
        for inc in incidents {
            for culprit in inc.culprits {
                counts[culprit, default: 0] += 1
            }
        }
        return counts
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { OffenderEntry(name: $0.key, count: $0.value) }
    }

    // MARK: - Streaks + recent

    /// A recurring problem — same title firing on multiple recent days.
    /// Not a strict "N days in a row" streak; instead "N days out of
    /// the window" which better matches the pattern users care about
    /// ("Docker is a problem 5 out of 7 days" is more useful than
    /// "Docker fired 3 days in a row"). Ordered by day count desc.
    private struct Streak: Identifiable {
        let id = UUID()
        let title: String
        let dayCount: Int
        let incidentCount: Int
        let peakSeverity: Severity
    }

    /// Minimum number of distinct days a title has to fire on to
    /// count as a "streak" worth surfacing. 3+ days over the visible
    /// window catches the "recurring" pattern without hitting on
    /// one-off bad days.
    private var streakMinDays: Int { 3 }

    private var streaks: [Streak] {
        var byTitle: [String: (days: Set<Date>, count: Int, peak: Severity)] = [:]
        let cal = Calendar.current
        for inc in incidents {
            let day = cal.startOfDay(for: inc.firstSeenAt)
            var entry = byTitle[inc.title] ?? (days: [], count: 0, peak: .ok)
            entry.days.insert(day)
            entry.count += 1
            entry.peak = max(entry.peak, inc.peakSeverity)
            byTitle[inc.title] = entry
        }
        return byTitle
            .compactMap { title, agg -> Streak? in
                guard agg.days.count >= streakMinDays else { return nil }
                return Streak(
                    title: title,
                    dayCount: agg.days.count,
                    incidentCount: agg.count,
                    peakSeverity: agg.peak
                )
            }
            .sorted { $0.dayCount > $1.dayCount }
    }

    /// Latest 15 incidents in the window, newest first. Kept bounded
    /// so the settings pane doesn't turn into a 500-row wall.
    private var sortedRecentIncidents: [DiagnosisIncident] {
        Array(incidents.sorted { $0.firstSeenAt > $1.firstSeenAt }.prefix(15))
    }

    // MARK: - Summary values

    private var worstRule: String? {
        var counts: [String: Int] = [:]
        for inc in incidents where inc.peakSeverity == .critical {
            counts[inc.title, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key
    }

    private var medianIncidentLabel: String {
        let durations = incidents.map(\.durationSeconds).sorted()
        guard !durations.isEmpty else { return "—" }
        let mid = durations[durations.count / 2]
        return MenuFormat.duration(seconds: mid)
    }

    private var longestIncidentLabel: String {
        guard let longest = incidents.map(\.durationSeconds).max(),
              longest > 0 else { return "—" }
        return MenuFormat.duration(seconds: longest)
    }

    // MARK: - Helpers

    private func color(for severity: Severity) -> Color {
        switch severity {
        case .ok:       return .blue
        case .warning:  return .orange
        case .critical: return .red
        }
    }
}

// MARK: - Grouping keys

private struct DayTitleKey: Hashable {
    let day: Date
    let title: String
}

private struct DaySeverityKey: Hashable {
    let day: Date
    let severity: Severity
}

private extension Severity {
    var label: String {
        switch self {
        case .ok:       return "OK"
        case .warning:  return "Warning"
        case .critical: return "Critical"
        }
    }
}
