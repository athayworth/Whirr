import SwiftUI
import WhirrCore

/// The last week: one sentence, then a compact day-by-day timeline.
struct HistorySectionView: View {
    @Bindable var monitor: SystemMonitor
    @State private var digest: HistoryDigest?
    @State private var tests: [ConnectionTestResult] = []

    var body: some View {
        SectionPage(title: "History") {
            if let digest {
                Text(digest.weekSentence)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(digest.days.enumerated()), id: \.element.id) { index, day in
                        DayRow(day: day, startsOpen: index == 0)
                        Divider()
                    }
                    FoldRow("Patterns", summary: digest.patterns.isEmpty ? "none this week" : "\(digest.patterns.count)",
                            key: "history.patterns") {
                        VStack(alignment: .leading, spacing: 4) {
                            if digest.patterns.isEmpty {
                                Text("No repeating problems this week.").foregroundStyle(.secondary)
                            }
                            ForEach(digest.patterns, id: \.self) { Text($0) }
                        }
                    }
                    Divider()
                    FoldRow("Connection tests", summary: "\(tests.count)", key: "history.tests") {
                        VStack(alignment: .leading, spacing: 4) {
                            if tests.isEmpty {
                                Text("No tests yet. Run one from Connection → Check my connection.").foregroundStyle(.secondary)
                            }
                            ForEach(tests.reversed().prefix(10)) { test in
                                HStack {
                                    Text(test.at.formatted(date: .abbreviated, time: .shortened))
                                    Spacer()
                                    Text(TestSummary.line(test)).foregroundStyle(.secondary).monospacedDigit()
                                }
                                .font(.callout)
                            }
                        }
                    }
                }
            } else {
                ProgressView("Reading history…").controlSize(.small)
            }
        }
        .task(id: monitor.net.connection.networkId) {
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func reload() async {
        let store = monitor.net.store
        let log = monitor.incidentLog
        let network = monitor.net.connection.networkId
        let now = Date()
        // Problems still going on aren't in the log yet; include them as
        // ongoing so today isn't missing what's happening now.
        let ongoing = monitor.verdict.stories.flatMap(\.members).map { m -> DiagnosisIncident in
            let d = m.diagnosis
            return DiagnosisIncident(title: d.title, peakSeverity: m.peakSeverity,
                                     firstSeenAt: m.firstSeenAt, lastSeenAt: now,
                                     culprits: d.culprits, tier: d.tier, area: d.area)
        }
        let (incidents, outages, aggs, saved) = await Task.detached(priority: .utility) {
            (log.incidents(from: now.addingTimeInterval(-8 * 86_400), to: now),
             store.outages(),
             store.aggregates(since: now.addingTimeInterval(-8 * 86_400)),
             store.tests())
        }.value
        guard !Task.isCancelled else { return }
        let changes = network.map { ChannelChangeLog.changes(aggs, networkId: $0) } ?? []
        // Minutes Whirr was actually watching this week (one record per
        // minute while running), so an empty week isn't called "quiet"
        // when Whirr barely saw it.
        let weekStart = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: now))!
        let watched = aggs.filter { $0.minute >= weekStart && (network == nil || $0.networkId == network) }.count
        digest = HistoryDigest.compute(incidents: incidents + ongoing, outages: outages, changes: changes,
                                       networkId: network, now: now, watchedMinutes: watched)
        tests = saved.filter { network == nil || $0.networkId == network }
    }
}

/// One day: a one-line summary that opens to its events.
private struct DayRow: View {
    let day: HistoryDay
    @State private var open: Bool

    init(day: HistoryDay, startsOpen: Bool) {
        self.day = day
        _open = State(initialValue: startsOpen)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(day.events) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(e.at.formatted(date: .omitted, time: .shortened))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .leading)
                        Chip(kind: e.kind)
                        Text(e.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if let d = e.durationSeconds {
                            Text(DurationText.words(seconds: d)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                if day.hasOlderMethodOutages {
                    Text("Some outage causes this day came from an older, less reliable method.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text(Self.title(day.day)).font(.headline)
                Spacer()
                Text(day.summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    static func title(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

private struct Chip: View {
    let kind: HistoryEvent.Kind

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch kind {
        case .mac: return "Mac"
        case .connection: return "Connection"
        case .wifi: return "Wi-Fi"
        }
    }

    private var color: Color {
        switch kind {
        case .mac: return .purple
        case .connection: return .blue
        case .wifi: return .teal
        }
    }
}

enum TestSummary {
    static func line(_ t: ConnectionTestResult) -> String {
        var parts: [String] = []
        if let d = t.nq?.downMbps { parts.append(String(format: "↓ %.0f Mbps", d)) }
        if let u = t.nq?.upMbps { parts.append(String(format: "↑ %.0f Mbps", u)) }
        if let i = t.nq?.idleLatencyMs, let l = t.nq?.loadedLatencyMs {
            parts.append(String(format: "%.0f → %.0f ms under load", i, l))
        }
        if let ch = t.link?.channel { parts.append("ch \(ch)") }
        return parts.isEmpty ? "Couldn't measure" : parts.joined(separator: "  ·  ")
    }
}

/// Dated outage list, newest first.
struct OutageList: View {
    let outages: [OutageRecord]

    var body: some View {
        let recent = outages
            .filter { $0.start > Date().addingTimeInterval(-30 * 86_400) }
            .sorted { $0.start > $1.start }
        if recent.isEmpty {
            Label("No outages recorded.", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(recent) { o in
                    HStack {
                        Text(o.start.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                        Text(OutageText.cause(o)).foregroundStyle(.secondary)
                        Spacer()
                        Text(OutageText.duration(o)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

enum OutageText {
    static func cause(_ o: OutageRecord) -> String { OutageReport.cause(o) }
    static func duration(_ o: OutageRecord) -> String { OutageReport.duration(o) }
    /// Plain text to paste into a chat or email with the provider.
    static func summary(_ outages: [OutageRecord]) -> String { OutageReport.summary(outages) }
}
