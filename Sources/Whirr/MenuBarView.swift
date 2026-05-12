import SwiftUI
import WhirrCore

struct MenuBarView: View {
    let monitor: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            diagnosesSection

            Divider()

            topProcessesSection

            Divider()

            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: monitor.statusIcon)
                .foregroundStyle(statusColor)
            Text("Whirr").font(.headline)
            Spacer()
            Text(statusLabel)
                .font(.caption)
                .foregroundStyle(statusColor)
        }
    }

    @ViewBuilder
    private var diagnosesSection: some View {
        if monitor.diagnoses.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("System running normally.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(monitor.diagnoses) { diagnosis in
                    DiagnosisRow(diagnosis: diagnosis)
                }
            }
        }
    }

    @ViewBuilder
    private var topProcessesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Top processes")
                .font(.caption)
                .foregroundStyle(.secondary)
            if monitor.topProcesses.isEmpty {
                Text("Sampling…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(monitor.topProcesses) { proc in
                    HStack {
                        Text(proc.name)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(String(format: "%.1f%%", proc.cpuPercent))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(memoryLine)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .controlSize(.small)
        }
    }

    private var memoryLine: String {
        let used = ByteCountFormatter.string(fromByteCount: Int64(monitor.systemSnapshot.memoryUsedBytes), countStyle: .memory)
        let swap = ByteCountFormatter.string(fromByteCount: Int64(monitor.systemSnapshot.swapUsedBytes), countStyle: .memory)
        return "RAM \(used) · swap \(swap)"
    }

    private var statusLabel: String {
        switch monitor.worstSeverity {
        case .ok:       return "OK"
        case .warning:  return "Warning"
        case .critical: return "Critical"
        }
    }

    private var statusColor: Color {
        switch monitor.worstSeverity {
        case .ok:       return .green
        case .warning:  return .yellow
        case .critical: return .red
        }
    }
}

private struct DiagnosisRow: View {
    let diagnosis: Diagnosis

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(diagnosis.title).font(.callout).bold()
                Text(diagnosis.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var iconName: String {
        switch diagnosis.severity {
        case .critical: return "exclamationmark.triangle.fill"
        case .warning:  return "exclamationmark.circle.fill"
        case .ok:       return "info.circle.fill"
        }
    }

    private var iconColor: Color {
        switch diagnosis.severity {
        case .critical: return .red
        case .warning:  return .yellow
        case .ok:       return .blue
        }
    }
}
