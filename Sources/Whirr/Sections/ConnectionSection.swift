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
    @State private var today: DaySummary?
    @State private var changes: [ChannelChange] = []
    @State private var historyLoaded = false
    @State private var copied = false

    var body: some View {
        SectionPage(title: "Connection") {
            LinkCard(connection: monitor.connection, testRunning: monitor.connectionTestPhase != nil)
            HopRows(connection: monitor.connection)
            if let today { TodayCard(summary: today) }

            SectionHeader(title: "Findings")
            FindingsList(monitor: monitor, area: .connection, emptyText: "No connection problems right now.")

            testSection
            channelSection
            changesSection
            outageSection
        }
        // One reload path, restarted whenever the network or period
        // changes, so a slow load for the old period can't land last.
        .task(id: ReloadKey(networkId: monitor.connection.networkId, period: period)) {
            // History grows a minute at a time; refresh on that cadence.
            while !Task.isCancelled {
                await reloadHistory()
                try? await Task.sleep(for: .seconds(60))
            }
        }
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
                              subtitle: "Stalls between your Mac and the router, compared at the same times of day.",
                              term: .channelWidth)
                Spacer()
                Picker("", selection: $period) {
                    Text("Evenings").tag(ChannelComparison.Period.evening)
                    Text("Daytime").tag(ChannelComparison.Period.daytime)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if let comparison {
                ChannelComparisonView(comparison: comparison, current: monitor.connection.link.map(ChannelGroup.init(link:)))
            } else {
                Text("Collecting…").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Channel changes

    private var changesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Channel changes",
                          subtitle: "Every change Whirr saw in the last 30 days. A new channel in the same band is usually the router switching on its own; a band change is usually your Mac or router moving between 2.4 and 5 GHz.",
                          term: .autoChannel)
            VStack(alignment: .leading, spacing: 8) {
                if !historyLoaded {
                    Text("Collecting…").foregroundStyle(.secondary)
                } else if changes.isEmpty {
                    Text("No changes seen in the last 30 days.").foregroundStyle(.secondary)
                }
                ForEach(changes.prefix(10)) { change in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.when(change)).font(.caption).foregroundStyle(.secondary)
                        Text(change.description)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
        }
    }

    static func when(_ change: ChannelChange) -> String {
        let at = change.at.formatted(date: .abbreviated, time: .shortened)
        guard let notBefore = change.notBefore else { return at }
        return "Sometime between \(notBefore.formatted(date: .abbreviated, time: .shortened)) and \(at) (Whirr wasn't watching)"
    }

    // MARK: Outages

    private var outageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Outages", subtitle: "Times the internet dropped in the last 30 days, and which side failed when Whirr could tell.",
                              term: .outage)
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
        let (aggs, outs) = await Task.detached(priority: .utility) {
            (store.aggregates(since: Date().addingTimeInterval(-ConnectionHistoryStore.retention)), store.outages())
        }.value
        // A reload for a period or network that's since changed must not
        // overwrite the newer one.
        guard !Task.isCancelled else { return }
        outages = outs.filter { networkId == nil || $0.networkId == networkId }
        comparison = networkId.map {
            ChannelComparison.compute(aggs, networkId: $0, current: current, period: period)
        }
        today = networkId.map { DaySummary.compute(aggs, networkId: $0, now: Date()) }
        changes = networkId.map { ChannelChangeLog.changes(aggs, networkId: $0) } ?? []
        historyLoaded = networkId != nil
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 5) {
                    Text(title).font(.title3.weight(.semibold))
                    if connection.link != nil && !connection.paused { InfoButton(term: .signalStrength) }
                }
                if connection.isWired {
                    Text("Wi-Fi measurements don't apply.").foregroundStyle(.secondary)
                } else if let link = connection.link {
                    facts(link)
                }
                if !connection.gatewayPingable {
                    Text("Your router doesn't answer Whirr's checks, so Whirr can only judge the connection as a whole — not inside your home separately.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
    }

    private func facts(_ link: WiFiLink) -> some View {
        let block = WiFiSpectrum.occupied(band: link.band, channel: link.channel, widthMHz: link.widthMHz)
        let channel = block.channels.count > 1
            ? "\(link.channel) (uses \(block.channels.lowerBound)–\(block.channels.upperBound))"
            : "\(link.channel)"
        return Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 8) {
            GridRow {
                fact("Band", link.band, .band)
                fact("Channel", channel, .channel)
                fact("Width", link.widthMHz > 0 ? "\(link.widthMHz) MHz" : "Unknown", .channelWidth)
            }
            GridRow {
                fact("Signal", "\(link.rssi) dBm", .signalStrength)
                fact("Above noise", "\(link.snr) dB", .snr)
                fact("Link rate", "\(Int(link.txRateMbps)) Mbps", .linkRate)
            }
        }
    }

    private func fact(_ label: String, _ value: String, _ term: Glossary.Term) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                InfoButton(term: term).font(.caption)
            }
            Text(value).font(.body.monospacedDigit())
        }
    }

    private var symbol: String {
        if connection.isWired { return "cable.connector" }
        guard let link = connection.link else { return "wifi.slash" }
        return link.quality == .weak ? "wifi.exclamationmark" : "wifi"
    }

    private var title: String {
        if connection.paused {
            return testRunning ? "Background checks paused during the test" : "Background checks paused while the Mac sleeps"
        }
        if connection.isWired { return "Wired connection" }
        guard let link = connection.link else { return "Not connected to Wi-Fi" }
        return "Wi-Fi signal: \(ConnectionText.signalWord(link))"
    }
}

private struct HopRows: View {
    let connection: ConnectionSnapshot

    var body: some View {
        let router = HopHealth(connection.gateway10m)
        VStack(spacing: 0) {
            if connection.gatewayPingable {
                row(icon: "wifi.router", name: "Your Mac → your router", term: .routerHop,
                    stats: connection.gateway10m,
                    stallingText: "Stalling between your Mac and the router.")
                Divider()
            }
            row(icon: "globe", name: "Your Mac → the internet", term: .internetHop,
                stats: connection.internet10m,
                stallingText: connection.gatewayPingable && router == .steady
                    ? "Stalling beyond your router." : "Stalling.")
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
    }

    private func status(_ health: HopHealth, stallingText: String) -> (String, Color) {
        switch health {
        case .measuring: return ("Measuring…", .secondary)
        case .steady: return ("Steady.", .secondary)
        case .minor: return ("A few stalls.", .secondary)
        case .stalling: return (stallingText, .orange)
        }
    }

    private func row(icon: String, name: String, term: Glossary.Term, stats: HopStats, stallingText: String) -> some View {
        let (text, color) = status(HopHealth(stats), stallingText: stallingText)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                LabelWithInfo(text: name, term: term, font: .headline)
                Text(text).foregroundStyle(color)
            }
            Spacer()
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 2) {
                GridRow {
                    header("Typical delay", .delay)
                    header("Stalls (10 min)", .stall)
                    header("Lost", .lost)
                }
                GridRow {
                    Text(stats.medianMs.map(ConnectionText.ms) ?? "—")
                    Text(stats.count == 0 ? "—" : "\(stats.spikes)")
                    Text(stats.count == 0 ? "—" : String(format: "%.0f%%", stats.lossPercent))
                }
                .font(.body.monospacedDigit())
            }
        }
        .padding(14)
    }

    private func header(_ text: String, _ term: Glossary.Term) -> some View {
        HStack(spacing: 3) {
            Text(text).font(.caption).foregroundStyle(.secondary)
            InfoButton(term: term).font(.caption)
        }
    }
}

private struct TodayCard: View {
    let summary: DaySummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text("Today").font(.headline)
                Text(summary.sentence).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
    }

    private var symbol: String {
        switch summary.verdict {
        case .notEnoughData: return "hourglass"
        case .steady: return "checkmark.circle"
        case .beyondRouter, .insideHome, .cantSeparate: return "exclamationmark.circle"
        }
    }

    private var color: Color {
        switch summary.verdict {
        case .notEnoughData, .steady: return .secondary
        case .beyondRouter, .insideHome, .cantSeparate: return .orange
        }
    }
}

private struct ReportRowView: View {
    let row: ReportRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            GradeChip(grade: row.grade)
            VStack(alignment: .leading, spacing: 4) {
                if let term = Self.term(row.id) {
                    LabelWithInfo(text: row.title, term: term, font: .headline)
                } else {
                    Text(row.title).font(.headline)
                }
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

extension ReportRowView {
    static func term(_ id: String) -> Glossary.Term? {
        switch id {
        case "speed": return .speed
        case "stability": return .stall
        case "underLoad": return .underLoad
        case "crowding": return .crowding
        default: return nil
        }
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

private struct ReloadKey: Equatable {
    let networkId: String?
    let period: ChannelComparison.Period
}
