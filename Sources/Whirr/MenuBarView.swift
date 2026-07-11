import SwiftUI
import WhirrCore

/// Top-level menu bar dropdown.
///
/// Layout, top to bottom:
///   • Header (icon + freshness)     ← pinned
///   • ScrollView                    ← the growable middle
///       - HeadroomSection (top-of-mind summary)
///       - DiagnosesSection (narratives + standalone + snoozed footer)
///       - HistorySection (30 min strip, when we have data)
///       - HarbrSection (dev servers — only when Harbr is configured)
///       - Top processes (unified — CPU + memory + I/O in one list)
///       - Docker containers (only when present)
///   • Daemon status row + footer    ← pinned
///
/// The ScrollView is capped at ~540 px so the whole panel comfortably
/// fits on a 13" MacBook screen — this is the fix for the runaway
/// height issue after we added HeadroomSection + duration/trend badges
/// + snooze affordances + HarbrSection. Pinned header/footer stay put
/// so the "just now" freshness label and Quit button never scroll off.
struct MenuBarView: View {
    @Bindable var monitor: SystemMonitor
    /// User's density preference. Read live from UserDefaults each render
    /// so toggling in Settings takes effect on the next menu open with
    /// no restart. Default: rich (false) — keeps existing users' UI as-is.
    @AppStorage(Preferences.Key.compactMode) private var compactMode = Preferences.defaultCompactMode

    /// Height of the scroll region. Chosen empirically for a 13"
    /// display — leaves ~120 px for header + footer + safe-area on top
    /// of the menu bar itself.
    ///
    /// **Why `.frame(height:)` not `.frame(maxHeight:)`:** the ScrollView
    /// sits inside a VStack with no explicit height constraint (the
    /// MenuBarExtra panel hugs its content). Under those conditions
    /// SwiftUI collapses a ScrollView with only `maxHeight` to zero
    /// because it has no basis to pick any other height — the original
    /// code comment warned about exactly this. Setting a fixed height
    /// gives it something concrete to render.
    private static let scrollHeight: CGFloat = 540

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 14)

            Divider().padding(.vertical, 10)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    HeadroomSection(
                        hasSampledYet: monitor.hasSampledYet,
                        headroom: monitor.headroom,
                        topHogFriendlyName: topHogFriendlyName
                    )

                    Divider()

                    DiagnosesSection(
                        hasSampledYet: monitor.hasSampledYet,
                        contexts: monitor.diagnosisContexts,
                        snoozeStore: monitor.snoozeStore,
                        compactMode: compactMode
                    )

                    if !monitor.trendHistory.isEmpty {
                        Divider()
                        HistorySection(history: monitor.trendHistory)
                    }

                    if !monitor.harbrStatuses.isEmpty {
                        Divider()
                        CollapsibleSection(
                            title: "Dev servers",
                            id: "harbr",
                            summary: harbrSummary
                        ) {
                            HarbrSection(statuses: monitor.harbrStatuses)
                        }
                    }

                    Divider()

                    CollapsibleSection(
                        title: "Top processes",
                        id: "topProcesses",
                        summary: topProcessesSummary
                    ) {
                        unifiedTopProcessesRows
                    }

                    if !monitor.dockerContainers.isEmpty {
                        Divider()
                        CollapsibleSection(
                            title: "Docker containers",
                            id: "docker",
                            summary: dockerSummary
                        ) {
                            dockerRows
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
            }
            .frame(height: Self.scrollHeight)

            Divider().padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 10) {
                // Only render the row when the state has something the
                // user can actually do — otherwise the row is 60 pt of
                // "sorry" text every menu open. Non-actionable state
                // (`.notFound`) still surfaces as the compact hint icon
                // in the footer below.
                if DaemonStatusRow(daemon: monitor.daemonManager).producesRow {
                    DaemonStatusRow(daemon: monitor.daemonManager)
                }
                footer
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(width: 380)
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

    // MARK: - Headroom + top-hog friendly name

    /// Look up the top hog's friendly name via ProcessDescriptor, so the
    /// headroom line reads "Google Chrome is holding 4.2 GB" instead of
    /// the raw "Google Chrome Helper (Renderer)" that the sampler saw.
    private var topHogFriendlyName: String? {
        guard let hogName = monitor.headroom.topHogName,
              let sample = monitor.topProcesses.first(where: { $0.name == hogName })
                       ?? monitor.topMemoryProcesses.first(where: { $0.name == hogName })
        else { return nil }
        return ProcessDescriptor.shared.friendlyName(for: sample)
    }

    // MARK: - Unified top processes

    /// Rows for the unified "Top processes" list. The header + collapsible
    /// wrapper live in the caller — this is just the content.
    ///
    /// Prior versions had three separate sections (Top by CPU / Top by
    /// memory / Top by disk I/O). Chrome typically appeared in all three
    /// and doubled the menu height. Now: one list — each row shows
    /// friendly name + CPU + memory + optional I/O badge. Sort:
    /// CPU-descending. We append big-memory holders that didn't make the
    /// CPU cut so idle-but-huge processes still surface.
    @ViewBuilder
    private var unifiedTopProcessesRows: some View {
        if unifiedRows.isEmpty {
            Text("Sampling…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            ForEach(unifiedRows) { proc in
                ProcessRow(
                    proc: proc,
                    expandedPid: $monitor.expandedPid,
                    parentLookup: parentLookup,
                    compactMode: compactMode
                ) {
                    UnifiedTrailing(proc: proc)
                }
            }
        }
    }

    /// Summary string shown next to the "Top processes" header when the
    /// section is collapsed — a compact "N processes · top: X 42%" hint.
    private var topProcessesSummary: String? {
        guard let top = unifiedRows.first else { return nil }
        let topName = ProcessDescriptor.shared.friendlyName(for: top)
        return "\(unifiedRows.count) shown · top: \(topName) \(MenuFormat.cpu(top.cpuPercent))"
    }

    /// Up to N by CPU + up to M additional big memory holders that
    /// aren't already in the CPU list. Compact mode cuts the totals in
    /// half so the whole menu shrinks noticeably.
    private var unifiedRows: [ProcessSample] {
        let (cpuMax, memMax) = compactMode ? (4, 2) : (6, 3)
        let byCpu = Array(monitor.topProcesses.prefix(cpuMax))
        let cpuPids = Set(byCpu.map(\.pid))
        let extraMemory = monitor.topMemoryProcesses
            .filter { !cpuPids.contains($0.pid) }
            .prefix(memMax)
        return byCpu + extraMemory
    }

    // MARK: - Docker

    /// Docker container rows. The collapsible wrapper owns the header.
    @ViewBuilder
    private var dockerRows: some View {
        ForEach(DockerContainerGroup.group(monitor.dockerContainers)) { group in
            DockerGroupView(
                group: group,
                expandedContainer: $monitor.expandedContainerId,
                dockerClient: monitor.dockerClient,
                history: monitor.dockerHistory
            )
        }
    }

    private var dockerSummary: String? {
        let count = monitor.dockerContainers.count
        guard count > 0 else { return nil }
        return count == 1 ? "1 container" : "\(count) containers"
    }

    private var harbrSummary: String? {
        let running = monitor.harbrStatuses.filter(\.isRunning).count
        let total = monitor.harbrStatuses.count
        guard total > 0 else { return nil }
        return "\(running)/\(total) running"
    }

    private var parentLookup: (Int32) -> ProcessSample? {
        let lookup = monitor.processesByPid
        return { pid in lookup[pid] }
    }

    // MARK: - Footer

    @Environment(\.openSettings) private var openSettings

    private var footer: some View {
        HStack(spacing: 6) {
            Text(memoryLine)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            DaemonStatusHint(daemon: monitor.daemonManager)
            Spacer()
            Button("Settings…") {
                // `LSUIElement=true` menu bar agent apps aren't
                // foregrounded when the user clicks the status icon —
                // the popover renders but the app itself stays
                // background. Calling `openSettings()` from that state
                // opens the Settings scene behind other windows (or, on
                // some macOS versions, not at all). Activating first
                // brings us to the foreground so the settings window
                // actually appears on top.
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
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

// MARK: - Trailing metrics for the unified row

/// Compact "CPU% · mem · (io)" trailing block for a process row.
/// One trailing view rather than three separate section-specific ones —
/// less repetition, and easier to keep the visual weight consistent.
struct UnifiedTrailing: View {
    let proc: ProcessSample

    var body: some View {
        HStack(spacing: 8) {
            if proc.diskIOBytesPerSec >= ioBadgeThreshold {
                Text(MenuFormat.rate(proc.diskIOBytesPerSec))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(MenuFormat.bytes(proc.memoryBytes))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Text(MenuFormat.cpu(proc.cpuPercent))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
        }
    }

    private var ioBadgeThreshold: UInt64 { 1_048_576 }
}
