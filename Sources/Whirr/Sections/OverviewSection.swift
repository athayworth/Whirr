import SwiftUI
import WhirrCore

/// "Is anything wrong, what, and what do I do?" — then the two areas.
struct OverviewSection: View {
    @Bindable var monitor: SystemMonitor

    var body: some View {
        SectionPage(title: "Overview") {
            AnswerCard(monitor: monitor, area: nil)
            let others = Array(monitor.verdict.stories.dropFirst())
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(others) { story in
                        Button { monitor.nav.openStory(story) } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: story.headline.symbol).foregroundStyle(story.headline.displayTint)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Also: \(story.phrase)")
                                    if let because = story.because {
                                        Text(because).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text("Why?").font(.caption).foregroundStyle(.tint)
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 5)
                    }
                }
            }
            HStack(alignment: .top, spacing: 14) {
                AreaTile(monitor: monitor, item: .mac, line: macLine)
                AreaTile(monitor: monitor, item: .connection, line: ConnectionText.summary(monitor.net.connection))
            }
        }
    }

    private var macLine: String {
        guard monitor.hasSampledYet else { return "Checking…" }
        let pressure: String
        switch monitor.systemSnapshot.memoryPressure {
        case .normal: pressure = "memory pressure normal"
        case .warning: pressure = "memory pressure elevated"
        case .critical: pressure = "memory pressure high"
        }
        let top = monitor.verdict.stories.first { $0.area == .mac }
        return (top.map { $0.phrase.sentenceCased } ?? "No problems right now") + " · " + pressure
    }
}

/// Clickable summary tile that jumps to its section.
struct AreaTile: View {
    @Bindable var monitor: SystemMonitor
    let item: SidebarItem
    let line: String

    var body: some View {
        Button {
            monitor.nav.selectedSection = item
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
            return outage.cause.summary
        }
        if c.paused { return "Background checks paused." }
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
        switch link.quality {
        case .strong: return "Strong"
        case .ok: return "OK"
        case .weak: return "Weak"
        }
    }

    static func ms(_ value: Double) -> String { String(format: "%.0f ms", value) }
}

extension String {
    var capitalizingFirst: String { prefix(1).uppercased() + dropFirst() }
}
