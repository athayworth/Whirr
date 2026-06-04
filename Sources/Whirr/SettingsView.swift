import SwiftUI

/// macOS Settings panel — opened from the menu bar's "Settings…" item.
/// Pure SwiftUI Form bound to `@AppStorage`; the rest of the app reads
/// values through `Preferences` and picks up changes on the next tick.
struct SettingsView: View {
    @AppStorage(Preferences.Key.samplingIntervalSeconds) private var samplingInterval =
        Preferences.defaultSamplingIntervalSeconds
    @AppStorage(Preferences.Key.notificationsEnabled) private var notificationsEnabled =
        Preferences.defaultNotificationsEnabled
    @AppStorage(Preferences.Key.notificationCooldownSeconds) private var notificationCooldown =
        Preferences.defaultNotificationCooldownSeconds

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
            about
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460, height: 320)
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
            Spacer()
            Text("MIT License · No network · No telemetry")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    }
}
