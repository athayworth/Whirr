import SwiftUI
import WhirrCore

struct HistorySectionView: View {
    @Bindable var monitor: SystemMonitor
    @State private var outages: [OutageRecord] = []
    @State private var tests: [ConnectionTestResult] = []

    var body: some View {
        SectionPage(title: "History") {
            if monitor.trendHistory.isEmpty {
                Text("Collecting…").foregroundStyle(.secondary)
            } else {
                HistorySection(history: monitor.trendHistory)
            }

            SectionHeader(title: "Connection outages", subtitle: "Last 30 days, on the network you're on now")
            OutageList(outages: outages)

            SectionHeader(title: "Connection tests", subtitle: "On the network you're on now")
            if tests.isEmpty {
                Text("No tests yet. Run one from Connection → Check my connection.").foregroundStyle(.secondary)
            } else {
                ForEach(tests.reversed().prefix(10)) { test in
                    HStack {
                        Text(test.at.formatted(date: .abbreviated, time: .shortened))
                        Spacer()
                        Text(TestSummary.line(test)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                }
            }

            InsightsView(log: monitor.incidentLog)
                .padding(.top, 6)
        }
        .task(id: monitor.connection.networkId) {
            // Same rule as Connection: another network's outages say
            // nothing about this one, so they aren't mixed in.
            let network = monitor.connection.networkId
            outages = monitor.connectionStore.outages().filter { network == nil || $0.networkId == network }
            tests = monitor.connectionStore.tests().filter { network == nil || $0.networkId == network }
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
