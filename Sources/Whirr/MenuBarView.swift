import SwiftUI
import WhirrCore

struct MenuBarView: View {
    let monitor: SystemMonitor
    /// Pid of the row that's currently expanded (showing details + actions).
    /// Nil = nothing expanded; only one at a time so the menu doesn't grow
    /// unbounded.
    @State private var expandedPid: Int32? = nil
    /// Same idea but for the Docker section — short container ID of the
    /// expanded row, nil for none. Separate state from expandedPid so a
    /// process and a container can be expanded simultaneously (different
    /// information shapes; no point forcing collapse on each other).
    @State private var expandedContainerId: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            diagnosesSection

            if !monitor.trendHistory.isEmpty {
                Divider()
                historySection
            }

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

    private var historyBuckets: [HistoryBucket] {
        HistoryBucket.bucket(monitor.trendHistory, bucketCount: 30, bucketSize: 60, endingAt: Date())
    }

    @ViewBuilder
    private var historySection: some View {
        let buckets = historyBuckets
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Last 30 minutes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(historySummary(buckets))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 1) {
                ForEach(buckets) { bucket in
                    Rectangle()
                        .fill(historyColor(for: bucket.severity))
                        .frame(height: 10)
                }
            }
        }
    }

    private func historyColor(for severity: Severity?) -> Color {
        guard let severity else { return Color.gray.opacity(0.15) }
        switch severity {
        case .ok:       return .green.opacity(0.6)
        case .warning:  return .yellow
        case .critical: return .red
        }
    }

    private func historySummary(_ buckets: [HistoryBucket]) -> String {
        let withData = buckets.filter { $0.severity != nil }
        guard !withData.isEmpty else { return "" }
        let criticalCount = withData.filter { $0.severity == .critical }.count
        if criticalCount > 0 {
            return "critical for \(criticalCount) of last \(withData.count) min"
        }
        let warningCount = withData.filter { $0.severity == .warning }.count
        if warningCount > 0 {
            return "warning for \(warningCount) of last \(withData.count) min"
        }
        return "healthy"
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
                    if diagnosis.kind == .narrative {
                        NarrativeCard(diagnosis: diagnosis)
                    } else {
                        DiagnosisRow(diagnosis: diagnosis)
                    }
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
                    ProcessRow(proc: proc, expandedPid: $expandedPid) {
                        HStack(spacing: 8) {
                            if proc.diskIOBytesPerSec >= ioBadgeThreshold {
                                Text(Self.formatRate(proc.diskIOBytesPerSec))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            Text(String(format: "%.1f%%", proc.cpuPercent))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !monitor.topMemoryProcesses.isEmpty {
                Text("Top by memory")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                ForEach(monitor.topMemoryProcesses) { proc in
                    ProcessRow(proc: proc, expandedPid: $expandedPid) {
                        Text(Self.formatBytes(proc.memoryBytes))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !monitor.dockerContainers.isEmpty {
                Text("Docker containers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                ForEach(DockerContainerGroup.group(monitor.dockerContainers)) { group in
                    DockerGroupView(group: group, expandedContainer: $expandedContainerId)
                }
            }

            if !topIOProcesses.isEmpty {
                Text("Top by disk I/O")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                ForEach(topIOProcesses) { proc in
                    HStack(spacing: 8) {
                        Text(proc.name)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(Self.formatRate(proc.diskIOBytesPerSec))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // Show an I/O badge on the CPU list when a process is moving at least
    // 1 MB/s — small enough to surface real activity, big enough to suppress
    // background noise from every idle process.
    private var ioBadgeThreshold: UInt64 { 1_048_576 }

    // Only show the dedicated I/O section when at least one process is
    // really moving bytes; otherwise it's just clutter.
    private var topIOProcesses: [ProcessSample] {
        let busy = monitor.topProcesses.sorted { $0.diskIOBytesPerSec > $1.diskIOBytesPerSec }
        guard let leader = busy.first, leader.diskIOBytesPerSec >= 5 * ioBadgeThreshold else { return [] }
        return Array(busy.prefix(3).filter { $0.diskIOBytesPerSec >= ioBadgeThreshold })
    }

    private static func formatRate(_ bytesPerSec: UInt64) -> String {
        let mb = Double(bytesPerSec) / 1_048_576
        if mb >= 10 { return String(format: "%.0f MB/s", mb) }
        return String(format: "%.1f MB/s", mb)
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
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

/// Header + member rows for one group of related containers. Members
/// for projects show indented under the group header with the compose
/// service name; ungrouped containers show flat without a header.
private struct DockerGroupView: View {
    let group: DockerContainerGroup
    @Binding var expandedContainer: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let project = group.project {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(project)
                        .font(.callout.weight(.medium))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(group.members.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatBytes(group.totalMemoryBytes))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(group.members) { container in
                DockerContainerRow(
                    container: container,
                    indented: group.project != nil,
                    expandedContainer: $expandedContainer
                )
            }
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

private struct DockerContainerRow: View {
    let container: DockerContainer
    let indented: Bool
    @Binding var expandedContainer: String?

    private var isExpanded: Bool { expandedContainer == container.id }
    private var displayName: String {
        // When inside a compose project the service name ("db") reads better
        // than the full container name ("supabase_db_pants-admin").
        container.composeService ?? container.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expandedContainer = isExpanded ? nil : container.id
            } label: {
                HStack(spacing: 8) {
                    if indented { Spacer().frame(width: 14) }
                    Text(displayName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if container.cpuPercent >= 1 {
                        Text(String(format: "%.0f%%", container.cpuPercent))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Text(formatBytes(container.memoryBytes))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                DockerContainerDetail(container: container)
                    .padding(.leading, indented ? 14 : 0)
            }
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

private struct DockerContainerDetail: View {
    let container: DockerContainer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            detailRow("id", container.id)
            detailRow("name", container.name)
            detailRow("image", container.image)
            if let status = container.status {
                detailRow("status", status)
            }
            if let project = container.composeProject {
                detailRow("project", project)
            }
            if let limit = container.memoryLimitBytes, limit > 0 {
                let pct = Double(container.memoryBytes) / Double(limit) * 100
                detailRow("limit", "\(formatBytes(limit)) (\(Int(pct))% used)")
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)
            Text(value)
                .font(.caption2)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

/// A clickable process row. Renders compactly (safety pill + name +
/// caller-supplied trailing content). Tapping it expands an inline
/// detail panel underneath; tapping again collapses. Only one row
/// across the whole menu can be expanded at a time (state lives at
/// MenuBarView level).
private struct ProcessRow<Trailing: View>: View {
    let proc: ProcessSample
    @Binding var expandedPid: Int32?
    @ViewBuilder var trailing: () -> Trailing

    private var isExpanded: Bool { expandedPid == proc.pid }
    private var safety: ProcessSafety { ProcessClassifier.classify(proc) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expandedPid = isExpanded ? nil : proc.pid
            } label: {
                HStack(spacing: 8) {
                    SafetyBadge(safety: safety)
                    Text(proc.name)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    trailing()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ProcessDetail(proc: proc, safety: safety)
            }
        }
    }
}

private struct ProcessDetail: View {
    let proc: ProcessSample
    let safety: ProcessSafety

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(safety.advice)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 3) {
                detailRow("pid", "\(proc.pid)")
                if let ppid = proc.parentPid {
                    detailRow("parent", "\(ppid)")
                }
                if let uid = proc.userId {
                    detailRow("uid", uid == 0 ? "root" : "\(uid)")
                }
                if let path = proc.executablePath {
                    detailRow("path", path)
                }
                if let cmd = proc.commandLine, cmd != proc.name, cmd != proc.executablePath {
                    detailRow("command", cmd)
                }
            }

            // Current resource use, plus growth indicator if memory is climbing.
            HStack(spacing: 6) {
                Text(String(format: "%.1f%% CPU", proc.cpuPercent))
                Text("·")
                Text(formatBytes(proc.memoryBytes))
                if let delta = proc.memoryDelta10MinBytes, delta >= 100 * 1_048_576 {
                    Text("·")
                    Text("+\(formatBytes(UInt64(delta))) /10m")
                        .foregroundStyle(.red)
                }
                if proc.sustainedIdleSamples >= 100 {
                    Text("·")
                    Text("idle \(proc.sustainedIdleSamples * 3 / 60)m")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Activity Monitor") {
                    let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
                    NSWorkspace.shared.open(url)
                }
                .controlSize(.small)

                if proc.userId == getuid() {
                    Button("Quit") {
                        _ = kill(proc.pid, SIGTERM)
                    }
                    .controlSize(.small)
                    .help("Sends SIGTERM. The process should exit cleanly.")
                }
                Spacer()
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)
            Text(value)
                .font(.caption2)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

private struct SafetyBadge: View {
    let safety: ProcessSafety

    var body: some View {
        Text(safety.label)
            .font(.caption2.monospaced())
            .foregroundStyle(textColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.18), in: Capsule())
            .help(safety.advice)
            .frame(minWidth: 42, alignment: .center)
    }

    private var tint: Color {
        switch safety {
        case .systemCritical: return .red
        case .systemService:  return .gray
        case .userApp:        return .blue
        case .helper:         return .purple
        case .devTool:        return .green
        case .unknown:        return .orange
        }
    }

    private var textColor: Color {
        switch safety {
        case .systemCritical: return .red
        case .systemService:  return .secondary
        case .userApp:        return .blue
        case .helper:         return .purple
        case .devTool:        return .green
        case .unknown:        return .orange
        }
    }
}

private struct NarrativeCard: View {
    let diagnosis: Diagnosis

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(severityColor)
                Text(diagnosis.title)
                    .font(.callout).bold()
            }
            Text(diagnosis.detail)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(severityColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(severityColor.opacity(0.35), lineWidth: 1)
        )
    }

    private var severityColor: Color {
        switch diagnosis.severity {
        case .critical: return .red
        case .warning:  return .orange
        case .ok:       return .blue
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
