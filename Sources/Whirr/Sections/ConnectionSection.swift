import AppKit
import SwiftUI
import WhirrCore

/// "Is it my Wi-Fi, my internet, or neither?" — live link, the two hops,
/// the on-demand test, per-channel history and the outage log.
struct ConnectionSection: View {
    @Bindable var monitor: SystemMonitor
    @State private var confirmingTest = false
    @State private var period: ChannelComparison.Period = .evening
    @State private var comparison: ChannelComparison?
    @State private var outages: [OutageRecord] = []
    @State private var copied = false

    var body: some View {
        SectionPage(title: "Connection") {
            LinkCard(connection: monitor.connection, testRunning: monitor.connectionTestPhase != nil)
            HopRows(connection: monitor.connection)

            SectionHeader(title: "Findings")
            FindingsList(monitor: monitor, area: .connection, emptyText: "Your connection looks healthy.")

            testSection
            channelSection
            outageSection
        }
        .task(id: monitor.connection.networkId) { await reloadHistory() }
        .onAppear {
            if monitor.pendingConnectionTest {
                monitor.pendingConnectionTest = false
                confirmingTest = true
            }
        }
        .confirmationDialog("Check your connection?", isPresented: $confirmingTest) {
            Button("Run test") { monitor.runConnectionTest() }
        } message: {
            Text("Takes about 30 seconds and uses roughly 500 MB of data. Anything else using the internet will be slower while it runs.")
        }
    }

    // MARK: Full test

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Check my connection",
                              subtitle: "Measures speed, delay when busy, and how crowded your Wi-Fi channel is.")
                Spacer()
                if let phase = monitor.connectionTestPhase {
                    ProgressView().controlSize(.small)
                    Text(Self.phaseText(phase)).foregroundStyle(.secondary)
                } else {
                    Button(monitor.latestConnectionTest == nil ? "Run test" : "Run again") { confirmingTest = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let test = monitor.latestConnectionTest {
                Text("Last run \(test.at.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(spacing: 8) {
                    ForEach(ConnectionReportCard.rows(for: test)) { row in
                        ReportRowView(row: row)
                    }
                }
            }
        }
    }

    static func phaseText(_ phase: ConnectionTestRunner.Phase) -> String {
        switch phase {
        case .measuringIdle: return "Measuring while quiet…"
        case .loading: return "Measuring speed and delay when busy…"
        case .scanning: return "Looking at nearby Wi-Fi…"
        case .done: return "Finishing…"
        }
    }

    // MARK: Channels

    private var channelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "How each Wi-Fi channel has done",
                              subtitle: "Your router may change channel when it restarts. Whirr compares them at the same times of day.")
                Spacer()
                Picker("", selection: $period) {
                    Text("Evenings").tag(ChannelComparison.Period.evening)
                    Text("Daytime").tag(ChannelComparison.Period.daytime)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: period) { Task { await reloadHistory() } }
            }
            if let comparison {
                ChannelComparisonView(comparison: comparison, current: monitor.connection.link.map(ChannelGroup.init(link:)))
            } else {
                Text("Collecting…").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Outages

    private var outageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Outages", subtitle: "Times the internet dropped in the last 30 days, and which side failed.")
                Spacer()
                if !outages.isEmpty {
                    Button(copied ? "Copied" : "Copy summary for your provider") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(OutageText.summary(outages), forType: .string)
                        copied = true
                    }
                }
            }
            OutageList(outages: outages)
        }
    }

    private func reloadHistory() async {
        let store = monitor.connectionStore
        let networkId = monitor.connection.networkId
        let current = monitor.connection.link.map(ChannelGroup.init(link:))
        let period = self.period
        let (aggs, outs) = await Task.detached {
            (store.aggregates(since: Date().addingTimeInterval(-ConnectionHistoryStore.retention)), store.outages())
        }.value
        outages = outs.filter { networkId == nil || $0.networkId == networkId }
        comparison = networkId.map {
            ChannelComparison.compute(aggs, networkId: $0, current: current, period: period)
        }
        copied = false
    }
}

// MARK: - Pieces

private struct LinkCard: View {
    let connection: ConnectionSnapshot
    let testRunning: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(.tint)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !connection.gatewayPingable {
                    Text("Your router doesn't answer Whirr's checks, so Whirr can only judge the internet as a whole — not Wi-Fi separately.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
    }

    private var symbol: String {
        if connection.isWired { return "cable.connector" }
        guard let link = connection.link else { return "wifi.slash" }
        switch ConnectionText.signalWord(link) {
        case "Strong": return "wifi"
        case "OK": return "wifi"
        default: return "wifi.exclamationmark"
        }
    }

    private var title: String {
        if connection.paused {
            return testRunning ? "Background checks paused during the test" : "Background checks paused while the Mac sleeps"
        }
        if connection.isWired { return "Wired connection" }
        guard let link = connection.link else { return "Not connected to Wi-Fi" }
        return "Wi-Fi signal: \(ConnectionText.signalWord(link))"
    }

    private var subtitle: String {
        if connection.isWired { return "Wi-Fi measurements don't apply." }
        guard let link = connection.link else { return "" }
        return "\(link.band), channel \(link.channel) · signal \(link.rssi) dBm, \(link.snr) dB above background noise · \(Int(link.txRateMbps)) Mbps link"
    }
}

private struct HopRows: View {
    let connection: ConnectionSnapshot

    var body: some View {
        VStack(spacing: 0) {
            if connection.gatewayPingable {
                row(icon: "wifi.router", name: "Your Mac → your router", stats: connection.gateway10m,
                    healthy: "Steady — your Wi-Fi is fine.", unhealthy: "Stalling — this is your Wi-Fi.")
                Divider()
            }
            row(icon: "globe", name: "Your Mac → the internet", stats: connection.internet10m,
                healthy: "Steady.", unhealthy: connection.gatewayPingable && isClean(connection.gateway10m)
                    ? "Stalling beyond your router — your provider's side." : "Stalling.")
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
    }

    private func isClean(_ h: HopStats) -> Bool { h.spikes < 3 && h.lossPercent < 1 }

    private func row(icon: String, name: String, stats: HopStats, healthy: String, unhealthy: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.headline)
                Text(stats.count < 30 ? "Measuring…" : (isClean(stats) ? healthy : unhealthy))
                    .foregroundStyle(stats.count < 30 || isClean(stats) ? Color.secondary : Color.orange)
            }
            Spacer()
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 2) {
                GridRow {
                    Text("Typical delay").font(.caption).foregroundStyle(.secondary)
                    Text("Stalls (10 min)").font(.caption).foregroundStyle(.secondary)
                    Text("Lost").font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text(stats.medianMs.map(ConnectionText.ms) ?? "—")
                    Text("\(stats.spikes)")
                    Text(String(format: "%.0f%%", stats.lossPercent))
                }
                .font(.body.monospacedDigit())
            }
        }
        .padding(14)
        .accessibilityElement(children: .combine)
    }
}

private struct ReportRowView: View {
    let row: ReportRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            GradeChip(grade: row.grade)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(.headline)
                Text(row.explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let fix = row.fix {
                    Label(fix, systemImage: "arrow.turn.down.right")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background.secondary))
        .accessibilityElement(children: .combine)
    }
}

private struct GradeChip: View {
    let grade: Grade

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 64)
            .padding(.vertical, 3)
            .background(Capsule().fill(color))
    }

    private var label: String {
        switch grade {
        case .good: return "Good"
        case .ok: return "OK"
        case .poor: return "Poor"
        case .unknown: return "—"
        }
    }

    private var color: Color {
        switch grade {
        case .good: return .green
        case .ok: return .orange
        case .poor: return .red
        case .unknown: return .gray
        }
    }
}

private struct ChannelComparisonView: View {
    let comparison: ChannelComparison
    let current: ChannelGroup?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if comparison.currentChannelWorsened, let current {
                Label("\(current.label) has had more stalls in your last three \(periodNoun(3)) than it did before.",
                      systemImage: "arrow.up.right")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if comparison.qualified.isEmpty && comparison.insufficient.isEmpty {
                Text("No data yet. Whirr builds this up as it watches your connection.").foregroundStyle(.secondary)
            }
            ForEach(comparison.qualified, id: \.group) { stat in
                HStack {
                    groupTitle(stat.group)
                    Spacer()
                    Text(String(format: "%.0f stalls/hour", stat.spikesPerHour)).monospacedDigit()
                    Text("over \(stat.sessions) \(periodNoun(stat.sessions))").foregroundStyle(.secondary)
                }
            }
            ForEach(comparison.insufficient, id: \.group) { need in
                HStack {
                    groupTitle(need.group)
                    Spacer()
                    Text("Not enough data yet — \(need.sessionsNeeded) more \(periodNoun(need.sessionsNeeded))")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
    }

    private func groupTitle(_ group: ChannelGroup) -> some View {
        HStack(spacing: 6) {
            Text(group.label).font(.headline)
            if group == current {
                Text("current").font(.caption2).padding(.horizontal, 6).background(.quaternary, in: Capsule())
            }
        }
    }

    private func periodNoun(_ n: Int) -> String {
        comparison.period == .evening ? (n == 1 ? "evening" : "evenings") : (n == 1 ? "day" : "days")
    }
}
