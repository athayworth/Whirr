import SwiftUI
import WhirrCore

/// Top-level menu bar dropdown. Pinned header (status + freshness) and
/// footer (RAM/swap + Quit) sandwich a scrollable middle so a stressed
/// machine with many diagnoses + a large Docker fleet doesn't push the
/// Quit button below the screen.
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
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 14)

            Divider().padding(.vertical, 12)

            // Middle section is NOT wrapped in a ScrollView: SwiftUI's
            // ScrollView inside MenuBarExtra(style: .window) collapses to
            // zero height when its `.frame(maxHeight:)` has no parent
            // height constraint, which hides every diagnosis and process
            // row. The lists below are already capped (8 CPU + 5 memory +
            // 3 I/O), so the menu won't get out of hand without it. If
            // overflow becomes a real problem (e.g. many Docker
            // containers), add a Docker-section cap before re-introducing
            // the ScrollView.
            VStack(alignment: .leading, spacing: 12) {
                DiagnosesSection(
                    hasSampledYet: monitor.hasSampledYet,
                    diagnoses: monitor.diagnoses
                )

                if !monitor.trendHistory.isEmpty {
                    Divider()
                    HistorySection(history: monitor.trendHistory)
                }

                Divider()

                topProcessesSection
            }
            .padding(.horizontal, 14)

            Divider().padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 10) {
                DaemonStatusRow(daemon: monitor.daemonManager)
                footer
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(width: 360)
        // The menu re-appears every time the user clicks the status item.
        // Refresh the daemon's status then so a flip in System Settings
        // (which doesn't notify us) lands on the next open instead of next
        // launch.
        .onAppear { monitor.daemonManager.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: monitor.statusIcon)
                .foregroundStyle(statusColor)
                .accessibilityLabel(statusAccessibilityLabel)
            Text("Whirr").font(.headline)
            Spacer()
            Text(headerStatusText)
                .font(.caption)
                .foregroundStyle(statusColor)
                .monospacedDigit()
                .accessibilityLabel(statusAccessibilityLabel)
        }
    }

    /// The header's status text is a freshness label when we have data,
    /// "Sampling…" before the first sample comes in. Reduces redundancy
    /// with the colored icon — color carries severity, the text carries
    /// "is this reading recent?".
    private var headerStatusText: String {
        guard monitor.hasSampledYet else { return "Sampling…" }
        let secondsAgo = Int(Date().timeIntervalSince(monitor.lastUpdated))
        if secondsAgo < 5 { return "just now" }
        if secondsAgo < 60 { return "\(secondsAgo)s ago" }
        let minutes = secondsAgo / 60
        return "\(minutes)m ago"
    }

    private var statusAccessibilityLabel: String {
        guard monitor.hasSampledYet else { return "Sampling, no data yet" }
        switch monitor.worstSeverity {
        case .ok:       return "Status OK"
        case .warning:  return "Status warning"
        case .critical: return "Status critical"
        }
    }

    private var statusColor: Color {
        guard monitor.hasSampledYet else { return .secondary }
        switch monitor.worstSeverity {
        case .ok:       return .green
        case .warning:  return .yellow
        case .critical: return .red
        }
    }

    // MARK: - Top processes

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
                    ProcessRow(proc: proc, expandedPid: $expandedPid, parentLookup: parentLookup) {
                        HStack(spacing: 8) {
                            if proc.diskIOBytesPerSec >= ioBadgeThreshold {
                                Text(MenuFormat.rate(proc.diskIOBytesPerSec))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            Text(MenuFormat.cpu(proc.cpuPercent))
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
                    ProcessRow(proc: proc, expandedPid: $expandedPid, parentLookup: parentLookup) {
                        Text(MenuFormat.bytes(proc.memoryBytes))
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
                    DockerGroupView(
                        group: group,
                        expandedContainer: $expandedContainerId,
                        dockerClient: monitor.dockerClient,
                        history: monitor.dockerHistory
                    )
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
                        Text(MenuFormat.rate(proc.diskIOBytesPerSec))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Show an I/O badge on the CPU list when a process is moving at least
    /// 1 MB/s — small enough to surface real activity, big enough to suppress
    /// background noise from every idle process.
    private var ioBadgeThreshold: UInt64 { 1_048_576 }

    /// Only show the dedicated I/O section when at least one process is
    /// really moving bytes; otherwise it's just clutter.
    private var topIOProcesses: [ProcessSample] {
        let busy = monitor.topProcesses.sorted { $0.diskIOBytesPerSec > $1.diskIOBytesPerSec }
        guard let leader = busy.first, leader.diskIOBytesPerSec >= 5 * ioBadgeThreshold else { return [] }
        return Array(busy.prefix(3).filter { $0.diskIOBytesPerSec >= ioBadgeThreshold })
    }

    /// Closure passed down to process drill-in so it can name and act on
    /// a process's parent without us threading the whole monitor through.
    private var parentLookup: (Int32) -> ProcessSample? {
        let lookup = monitor.processesByPid
        return { pid in lookup[pid] }
    }

    // MARK: - Footer

    @Environment(\.openSettings) private var openSettings

    private var footer: some View {
        HStack {
            Text(memoryLine)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Settings…") { openSettings() }
                .keyboardShortcut(",")
                .controlSize(.small)
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
}
