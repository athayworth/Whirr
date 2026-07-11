import SwiftUI
import AppKit
import WhirrCore

/// macOS Settings panel — opened from the menu bar's "Settings…" item.
/// Pure SwiftUI Form bound to `@AppStorage`; the rest of the app reads
/// values through `Preferences` and picks up changes on the next tick.
struct SettingsView: View {
    @ObservedObject var updater: UpdaterController
    /// Outcome of loading rules.json at startup. Drives the status hint
    /// in the Rules tab — "loaded", "no file yet", "malformed", etc.
    let rulesLoadResult: RulesConfigStore.LoadResult
    /// The monitor's incident log — drives the Insights charts. Passed
    /// through so the settings sheet reads the same instance the
    /// pipeline writes into, i.e., recent incidents show up immediately
    /// without a file re-read.
    let incidentLog: IncidentLog

    @AppStorage(Preferences.Key.samplingIntervalSeconds) private var samplingInterval =
        Preferences.defaultSamplingIntervalSeconds
    @AppStorage(Preferences.Key.notificationsEnabled) private var notificationsEnabled =
        Preferences.defaultNotificationsEnabled
    @AppStorage(Preferences.Key.notificationCooldownSeconds) private var notificationCooldown =
        Preferences.defaultNotificationCooldownSeconds
    @AppStorage(Preferences.Key.notifyOnRecovery) private var notifyOnRecovery =
        Preferences.defaultNotifyOnRecovery
    @AppStorage(Preferences.Key.compactMode) private var compactMode =
        Preferences.defaultCompactMode

    /// SwiftUI's Slider on the macOS 26 SDK has a long preferred initializer
    /// that breaks overload resolution when you also pass `step:`. We bind
    /// to these snapped bindings that round to the desired step instead, so
    /// the slider call site can stay on the short two-arg form.
    private var samplingIntervalBinding: Binding<Double> {
        Binding(
            get: { samplingInterval },
            set: { samplingInterval = $0.rounded() }
        )
    }
    private var notificationCooldownBinding: Binding<Double> {
        Binding(
            get: { notificationCooldown },
            set: { notificationCooldown = (($0 / 60).rounded()) * 60 }
        )
    }

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            notifications
                .tabItem { Label("Notifications", systemImage: "bell") }
            InsightsView(log: incidentLog)
                .tabItem { Label("Insights", systemImage: "chart.bar.xaxis") }
            rules
                .tabItem { Label("Rules", systemImage: "list.bullet.rectangle") }
            about
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        // Wider + taller than a typical Settings panel because Insights
        // packs multiple charts + a scrollable incident list. The panel
        // itself is resizable — a MacBook Air user can shrink it, a
        // Studio Display user can grow it to see everything at once.
        .frame(minWidth: 560, idealWidth: 640, minHeight: 500, idealHeight: 620)
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Sampling interval")
                        Spacer()
                        Text("\(samplingInterval, specifier: "%.0f") s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    let samplingRange = Preferences.minSamplingIntervalSeconds...Preferences.maxSamplingIntervalSeconds
                    HStack(spacing: 8) {
                        Text("\(Int(Preferences.minSamplingIntervalSeconds))s")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Slider(value: samplingIntervalBinding, in: samplingRange)
                        Text("\(Int(Preferences.maxSamplingIntervalSeconds))s")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text("How often Whirr re-reads system state. Lower = fresher diagnoses, slightly more battery; higher = lighter, but laggier menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Compact menu", isOn: $compactMode)
                Text("Drops the duration/trend badges and shrinks process rows for a shorter menu. Detailed mode (the default) keeps everything visible so you can see how long each condition has been active and which direction it's trending.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Reset to defaults", role: .destructive) {
                    resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    // MARK: - Notifications

    private var notifications: some View {
        Form {
            Section {
                Toggle("Notify on new critical diagnoses", isOn: $notificationsEnabled)
                Text("Whirr posts a macOS notification the first time a diagnosis becomes critical. A per-condition cooldown stops flapping problems from spamming you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Notify when things clear up", isOn: $notifyOnRecovery)
                    .disabled(!notificationsEnabled)
                Text("Send a silent \"all clear\" notification when a previously-critical diagnosis resolves. Off by default — turn on if you want to know the machine is safe again without checking the menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Cooldown")
                        Spacer()
                        Text(cooldownLabel)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    let cooldownRange = Preferences.minNotificationCooldownSeconds...Preferences.maxNotificationCooldownSeconds
                    HStack(spacing: 8) {
                        Text("1m")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Slider(value: notificationCooldownBinding, in: cooldownRange)
                        Text("60m")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text("After a notification, the same condition won't notify again until the cooldown lapses and the condition has cleared at least once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!notificationsEnabled)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var cooldownLabel: String {
        let minutes = Int(notificationCooldown / 60)
        return "\(minutes) min"
    }

    // MARK: - Rules

    @State private var rulesActionMessage: String? = nil

    private var rules: some View {
        Form {
            Section {
                Text("Edit `~/Library/Application Support/Whirr/rules.json` to tune thresholds and mute individual rules. Changes take effect on the next Whirr launch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent("Status") {
                    Text(rulesStatusLabel)
                        .foregroundStyle(rulesStatusColor)
                        .font(.caption.monospaced())
                }
                LabeledContent("Location") {
                    Text(rulesPath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            Section {
                HStack {
                    Button("Edit rules.json") {
                        ensureFileExists()
                        NSWorkspace.shared.open(URL(fileURLWithPath: rulesPath))
                    }
                    Button("Show in Finder") {
                        ensureFileExists()
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rulesPath)])
                    }
                    Spacer()
                    Button("Reset to defaults") {
                        do {
                            try RulesConfigStore().write(.default)
                            rulesActionMessage = "Wrote defaults. Restart Whirr to apply."
                        } catch {
                            rulesActionMessage = "Couldn't write defaults: \(error.localizedDescription)"
                        }
                    }
                }
                if let rulesActionMessage {
                    Text(rulesActionMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var rulesPath: String { RulesConfigStore.defaultPath }

    private var rulesStatusLabel: String {
        switch rulesLoadResult {
        case .loaded:                  return "user config in use"
        case .absent:                  return "no file — using defaults"
        case .malformed(let reason):   return "malformed: \(reason) — defaults in use"
        case .versionMismatch(let v):  return "format v\(v) unsupported — defaults in use"
        }
    }

    private var rulesStatusColor: Color {
        switch rulesLoadResult {
        case .loaded:                  return .green
        case .absent:                  return .secondary
        case .malformed, .versionMismatch: return .orange
        }
    }

    /// Open / Show-in-Finder both expect a file on disk. If the user
    /// hasn't created one yet, seed it with the embedded defaults so they
    /// have a complete starting point to edit.
    private func ensureFileExists() {
        let store = RulesConfigStore()
        guard !FileManager.default.fileExists(atPath: store.path) else { return }
        try? store.writeDefaults()
    }

    // MARK: - About

    private var about: some View {
        VStack(spacing: 12) {
            Spacer()
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }
            Text("Whirr")
                .font(.title2.weight(.semibold))
            Text(versionString)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("A local, privacy-respecting diagnosis of why your Mac is slow.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            updateRow
                .padding(.top, 4)

            Spacer()
            Text("MIT License · No network (besides update checks) · No telemetry")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var updateRow: some View {
        if updater.hasFeedURL {
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        } else {
            Text("Auto-update not yet configured.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(v) (build \(b))"
    }

    // MARK: - Actions

    private func resetToDefaults() {
        samplingInterval = Preferences.defaultSamplingIntervalSeconds
        notificationsEnabled = Preferences.defaultNotificationsEnabled
        notificationCooldown = Preferences.defaultNotificationCooldownSeconds
        notifyOnRecovery = Preferences.defaultNotifyOnRecovery
        compactMode = Preferences.defaultCompactMode
    }
}
