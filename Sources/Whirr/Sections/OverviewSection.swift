import SwiftUI
import WhirrCore

/// "Is it my Mac or my connection, and what's the one thing to do?"
struct OverviewSection: View {
    @Bindable var monitor: SystemMonitor

    var body: some View {
        SectionPage(title: "Overview") {
            VerdictCard(monitor: monitor)
            if !monitor.verdict.also.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Also").font(.headline)
                    ForEach(monitor.verdict.also) { context in
                        Button {
                            monitor.selectedSection = SidebarItem.allCases.first { $0.area == context.diagnosis.area }
                        } label: {
                            HStack {
                                Image(systemName: context.symbol).foregroundStyle(context.displayTint)
                                Text(context.diagnosis.title)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }
            }
            HStack(alignment: .top, spacing: 14) {
                AreaTile(monitor: monitor, item: .mac, line: macLine)
                AreaTile(monitor: monitor, item: .connection, line: ConnectionText.summary(monitor.connection))
            }
        }
    }

    private var macLine: String {
        guard monitor.hasSampledYet else { return "Checking…" }
        return monitor.headroom.headline
    }
}

/// The big card at the top of Overview.
private struct VerdictCard: View {
    @Bindable var monitor: SystemMonitor
    @State private var confirming: SuggestedAction?

    var body: some View {
        Group {
            if !monitor.hasSampledYet {
                card(tint: .secondary, symbol: "hourglass", title: "Checking your Mac and connection…",
                     detail: "This takes a few seconds.")
            } else if let headline = monitor.verdict.headline {
                card(tint: headline.diagnosis.severity.tint, symbol: headline.symbol,
                     title: headline.diagnosis.title, detail: headline.diagnosis.detail) {
                    HStack(spacing: 10) {
                        if let action = headline.diagnosis.action {
                            Button(action.label) {
                                if ActionText.needsConfirmation(action) { confirming = action } else { monitor.perform(action) }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(headline.diagnosis.severity.tint)
                            .controlSize(.large)
                        }
                        Button("Not now") { monitor.snoozeStore.snooze(headline.diagnosis.title) }
                            .help("Snooze for 1 hour")
                        Button("This is normal for me") { monitor.snoozeStore.mute(headline.diagnosis.title) }
                        Spacer()
                        Text("for \(MenuFormat.duration(seconds: headline.durationSeconds))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if let first = monitor.verdict.pending.first {
                card(tint: .secondary, symbol: "eye",
                     title: "Keeping an eye on something",
                     detail: "\(first.diagnosis.title) just started. Whirr waits a couple of minutes before raising a problem, so brief blips stay quiet. Details are in the \(SidebarItem.allCases.first { $0.area == first.diagnosis.area }?.title ?? "relevant") section.")
            } else {
                card(tint: .green, symbol: "checkmark.circle.fill",
                     title: "Everything's running smoothly",
                     detail: "Whirr keeps watching your Mac and your connection in the background and will let you know if something needs attention.")
            }
        }
        .confirmationDialog(
            confirming?.label ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { action in
            Button(action.label, role: .destructive) { monitor.perform(action) }
        } message: { Text(ActionText.confirmation(for: $0)) }
    }

    private func card<Actions: View>(
        tint: Color, symbol: String, title: String, detail: String,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title).font(.title2.weight(.semibold))
            }
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            actions()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }
}

/// Clickable summary tile that jumps to its section.
struct AreaTile: View {
    @Bindable var monitor: SystemMonitor
    let item: SidebarItem
    let line: String

    var body: some View {
        Button {
            monitor.selectedSection = item
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: item.symbol).font(.title3)
                    Text(item.title).font(.headline)
                    Spacer()
                    StatusDot(severity: item.area.flatMap { monitor.verdict.areaSeverity[$0] }, sampled: monitor.hasSampledYet)
                }
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title): \(line)")
        .accessibilityHint("Opens the \(item.title) section")
    }
}

/// Green / orange / red dot; empty ring before the first sample.
struct StatusDot: View {
    let severity: Severity?
    var sampled = true

    var body: some View {
        Circle()
            .fill(sampled ? (severity ?? .ok).tint : Color.secondary.opacity(0.4))
            .frame(width: 9, height: 9)
            .accessibilityLabel(sampled ? label : "Checking")
    }

    private var label: String {
        switch severity ?? .ok {
        case .ok: return "OK"
        case .warning: return "Needs attention"
        case .critical: return "Problem"
        }
    }
}

/// Plain-language connection phrases shared by Overview and Connection.
enum ConnectionText {
    static func summary(_ c: ConnectionSnapshot) -> String {
        if let outage = c.currentOutage {
            return outage.cause == .isp ? "Internet line is down (router is fine)." : "Router isn't responding."
        }
        if c.paused { return "Paused while the Mac sleeps." }
        guard c.internet1m.count > 0 else { return "Checking…" }
        var parts: [String] = []
        if let link = c.link {
            parts.append("Wi-Fi signal \(signalWord(link).lowercased())")
        } else if c.isWired {
            parts.append("Wired")
        }
        if c.gatewayPingable, let g = c.gateway1m.medianMs { parts.append("router \(ms(g))") }
        if let i = c.internet1m.medianMs { parts.append("internet \(ms(i))") }
        return parts.joined(separator: " · ").capitalizingFirst
    }

    static func signalWord(_ link: WiFiLink) -> String {
        if link.rssi >= -60 && link.snr >= 25 { return "Strong" }
        if link.rssi >= -70 && link.snr >= 20 { return "OK" }
        return "Weak"
    }

    static func ms(_ value: Double) -> String { String(format: "%.0f ms", value) }
}

extension String {
    var capitalizingFirst: String { prefix(1).uppercased() + dropFirst() }
}
