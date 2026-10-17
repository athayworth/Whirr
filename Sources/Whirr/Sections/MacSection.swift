import SwiftUI
import WhirrCore

struct MacSection: View {
    @Bindable var monitor: SystemMonitor
    @AppStorage(Preferences.Key.compactMode) private var compactMode = Preferences.defaultCompactMode

    var body: some View {
        SectionPage(title: "Mac") {
            AnswerCard(monitor: monitor, area: .mac)
            FindingsList(monitor: monitor, area: .mac)
            KeyFacts(facts: [
                ("Memory pressure", pressureWord(monitor.systemSnapshot.memoryPressure), .memoryPressure),
                ("Workload", workloadWord(monitor.systemSnapshot.loadAverage.oneMinute), .workload),
                ("Free disk", monitor.systemSnapshot.rootDiskTotalBytes > 0
                    ? MenuFormat.bytes(monitor.systemSnapshot.rootDiskFreeBytes) : "—", .diskSpace),
            ])

            VStack(alignment: .leading, spacing: 4) {
                FoldRow("What's using your Mac", summary: topUserSummary, term: .cpu, key: "mac.processes") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Click a row for details and options. CPU is on the right.")
                            .font(.callout).foregroundStyle(.secondary)
                        if rows.isEmpty { Text("Checking…").foregroundStyle(.secondary) }
                        ForEach(rows) { proc in
                            ProcessRow(proc: proc, expandedPid: $monitor.expandedPid,
                                       parentLookup: parentLookup, compactMode: compactMode,
                                       secondsPerSample: monitor.secondsPerSample) {
                                UnifiedTrailing(proc: proc)
                            }
                        }
                    }
                }
                Divider()
                FoldRow("All measurements", key: "mac.measurements") { facts }
                Divider()
                FoldRow("Background helper", summary: helperSummary, key: "mac.helper") {
                    daemonStatus
                }
            }
        }
    }

    private var topUserSummary: String? {
        guard let top = monitor.topProcesses.first else { return nil }
        return "\(ProcessDescriptor.shared.friendlyName(for: top)) \(MenuFormat.cpu(top.cpuPercent))"
    }

    private var helperSummary: String {
        switch monitor.daemonStatus {
        case .fresh: return "running"
        case .stale: return "not responding"
        case .undecodable: return "out of date"
        case .absent: return "not installed"
        }
    }

    // MARK: Facts

    private var facts: some View {
        let s = monitor.systemSnapshot
        return Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            GridRow {
                fact("Memory pressure", pressureWord(s.memoryPressure), .memoryPressure)
                fact("Memory in use", MenuFormat.bytes(s.memoryUsedBytes), nil)
            }
            GridRow {
                fact("Memory available", MenuFormat.bytes(s.memoryAvailableBytes), nil)
                fact("Headroom", monitor.hasSampledYet ? monitor.headroom.headline : "—", nil)
            }
            GridRow {
                fact("Parked on disk (swap)", MenuFormat.bytes(s.swapUsedBytes), .swap)
                fact("Free disk space", s.rootDiskTotalBytes > 0
                     ? "\(MenuFormat.bytes(s.rootDiskFreeBytes)) (\(Int(100 - s.rootDiskPercentUsed))%)" : "—", .diskSpace)
            }
            GridRow {
                fact("Heat", heatWord(s.thermalState), .heat)
                fact("Workload", workloadWord(s.loadAverage.oneMinute), .workload)
            }
        }
    }

    private func fact(_ label: String, _ value: String, _ term: Glossary.Term?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                if let term { InfoButton(term: term).font(.caption) }
            }
            Text(value).font(.body.monospacedDigit())
        }
    }

    private func pressureWord(_ p: MemoryPressure) -> String {
        switch p {
        case .normal: return "Normal"
        case .warning: return "Elevated"
        case .critical: return "High"
        }
    }

    private func heatWord(_ t: ThermalState) -> String {
        switch t {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot — slowing down to cool"
        case .critical: return "Very hot — heavily slowed"
        }
    }

    private func workloadWord(_ load: Double) -> String {
        let ratio = load / Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))
        if ratio < 0.7 { return "Light" }
        if ratio < 1.5 { return "Busy" }
        return String(format: "Overloaded (%.1f× capacity)", ratio)
    }

    // MARK: Processes

    /// Top CPU users plus big memory holders that didn't make the CPU cut.
    private var rows: [ProcessSample] {
        let byCpu = Array(monitor.topProcesses.prefix(8))
        let cpuPids = Set(byCpu.map(\.pid))
        return byCpu + monitor.topMemoryProcesses.filter { !cpuPids.contains($0.pid) }.prefix(4)
    }

    private var topHogFriendlyName: String? {
        guard let hogName = monitor.headroom.topHogName,
              let sample = monitor.topProcesses.first(where: { $0.name == hogName })
                       ?? monitor.topMemoryProcesses.first(where: { $0.name == hogName })
        else { return nil }
        return ProcessDescriptor.shared.friendlyName(for: sample)
    }

    private var parentLookup: (Int32) -> ProcessSample? {
        let lookup = monitor.processesByPid
        return { lookup[$0] }
    }

    // MARK: Daemon

    @ViewBuilder
    private var daemonStatus: some View {
        if monitor.daemonStatus == .undecodable {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("System-process view unavailable").font(.headline)
                    Text("Whirr's background helper is out of date, so system processes (like backups and Spotlight) aren't visible.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("How to update it") { monitor.nav.presentedHowTo = .reinstallSampler }
                        .controlSize(.small)
                }
            }
            .padding(.top, 8)
        } else if DaemonStatusRow(daemon: monitor.daemonManager).producesRow {
            DaemonStatusRow(daemon: monitor.daemonManager)
        }
    }
}

/// Compact "CPU% · mem · (io)" trailing block for a process row.
struct UnifiedTrailing: View {
    let proc: ProcessSample

    var body: some View {
        HStack(spacing: 8) {
            if proc.diskIOBytesPerSec >= 1_048_576 {
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
}
