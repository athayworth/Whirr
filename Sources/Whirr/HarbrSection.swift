import SwiftUI
import WhirrCore

/// Dev-servers panel — rendered inside a CollapsibleSection when Harbr's
/// config is present. Header ownership moved to the collapsible wrapper
/// so this view is just the list of rows.
struct HarbrSection: View {
    let statuses: [HarbrProjectStatus]

    var body: some View {
        if statuses.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(statuses) { status in
                    HarbrRow(status: status)
                }
            }
        }
    }
}

private struct HarbrRow: View {
    let status: HarbrProjectStatus

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(status.project.name)
                    .font(.callout)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let usage = usageLabel {
                Text(usage)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var iconName: String {
        status.isRunning ? "circle.fill" : "circle"
    }

    private var iconColor: Color {
        status.isRunning ? .green : .secondary
    }

    /// Subtitle: port number + hint about whether we could attribute a
    /// process (helpful when a Docker-hosted service is holding the port
    /// but we can't see it in the user's process table).
    private var subtitle: String {
        if status.isRunning, status.processName == nil {
            return ":\(status.project.port) · listening"
        }
        if let name = status.processName {
            return ":\(status.project.port) · \(name)"
        }
        return ":\(status.project.port) · stopped"
    }

    private var usageLabel: String? {
        guard status.isRunning else { return nil }
        // Prefer memory since it's the most consistently-attributable
        // signal for dev servers; CPU is spiky (compile bursts).
        if let mem = status.memoryBytes, mem > 0 {
            return MenuFormat.bytes(mem)
        }
        if let cpu = status.cpuPercent {
            return MenuFormat.cpu(cpu)
        }
        return nil
    }

    private var accessibilityLabel: String {
        let state = status.isRunning ? "running" : "stopped"
        return "\(status.project.name) on port \(status.project.port), \(state)"
    }
}
