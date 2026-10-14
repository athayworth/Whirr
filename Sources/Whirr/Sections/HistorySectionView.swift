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

            SectionHeader(title: "Connection outages", subtitle: "Last 30 days")
            OutageList(outages: outages)

            SectionHeader(title: "Connection tests")
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
        .task {
            outages = monitor.connectionStore.outages()
            tests = monitor.connectionStore.tests()
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
                        Text(OutageText.cause(o.cause)).foregroundStyle(.secondary)
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
    static func cause(_ c: OutageCause) -> String {
        switch c {
        case .router: return "Router stopped responding"
        case .isp: return "Internet line down"
        case .wifiDisconnected: return "Wi-Fi disconnected"
        }
    }

    static func duration(_ o: OutageRecord) -> String {
        guard let d = o.duration else { return "ongoing" }
        return MenuFormat.duration(seconds: Int(d))
    }

    /// Plain text to paste into a chat or email with the provider.
    static func summary(_ outages: [OutageRecord]) -> String {
        let recent = outages.filter { $0.start > Date().addingTimeInterval(-30 * 86_400) }.sorted { $0.start < $1.start }
        let lines = recent.map { "• \($0.start.formatted(date: .abbreviated, time: .shortened)) — \(cause($0.cause)), \(duration($0))" }
        let isp = recent.filter { $0.cause == .isp }.count
        return """
        Connection outages in the last 30 days: \(recent.count) (\(isp) where the router was working but the internet line was down).

        \(lines.joined(separator: "\n"))

        Recorded automatically by Whirr, which pings the home router and an internet server every 2 seconds.
        """
    }
}
