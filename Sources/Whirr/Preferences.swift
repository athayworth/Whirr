import Foundation

/// Centralized accessors for user-tunable behavior. Backed by
/// `UserDefaults.standard`; the Settings sheet binds via `@AppStorage`,
/// the sampling loop and notification service read live values each
/// iteration, so changes apply on the next tick without a restart.
///
/// Why a struct over scattered `@AppStorage` strings: the keys + clamps +
/// defaults are all in one place, so a typo can't introduce a silent
/// regression like "interval was being clamped to 60 because someone
/// passed seconds where minutes were expected."
enum Preferences {
    enum Key {
        static let samplingIntervalSeconds = "preferences.samplingIntervalSeconds"
        static let notificationsEnabled    = "preferences.notificationsEnabled"
        static let notificationCooldownSeconds = "preferences.notificationCooldownSeconds"
        static let notifyOnRecovery        = "preferences.notifyOnRecovery"
        static let compactMode             = "preferences.compactMode"
        static let hasCompletedOnboarding  = "preferences.hasCompletedOnboarding"
        static let alwaysShowDeveloper     = "preferences.alwaysShowDeveloper"
    }

    // MARK: - Sampling cadence

    /// How often to take a system snapshot. 3 seconds is the default and
    /// what the rules' "sustained for N samples" thresholds are calibrated
    /// against. Below 1 s the in-process CPU% deltas get noisy; above 15 s
    /// the menu feels stale on every open.
    static let defaultSamplingIntervalSeconds: Double = 3
    static let minSamplingIntervalSeconds: Double = 1
    static let maxSamplingIntervalSeconds: Double = 15

    static var samplingIntervalSeconds: Double {
        let stored = UserDefaults.standard.double(forKey: Key.samplingIntervalSeconds)
        // UserDefaults returns 0.0 for unset doubles — treat that as "not
        // configured" and use the default.
        guard stored > 0 else { return defaultSamplingIntervalSeconds }
        return stored.clamped(to: minSamplingIntervalSeconds...maxSamplingIntervalSeconds)
    }

    // MARK: - Notifications

    static let defaultNotificationsEnabled = true

    static var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: Key.notificationsEnabled) as? Bool
            ?? defaultNotificationsEnabled
    }

    /// Per-title cooldown before a critical diagnosis can re-notify. 5 min
    /// is the sweet spot — long enough that flapping conditions don't spam,
    /// short enough that a recurring problem actually surfaces.
    static let defaultNotificationCooldownSeconds: Double = 300
    static let minNotificationCooldownSeconds: Double = 60
    static let maxNotificationCooldownSeconds: Double = 3600

    static var notificationCooldownSeconds: Double {
        let stored = UserDefaults.standard.double(forKey: Key.notificationCooldownSeconds)
        guard stored > 0 else { return defaultNotificationCooldownSeconds }
        return stored.clamped(to: minNotificationCooldownSeconds...maxNotificationCooldownSeconds)
    }

    // MARK: - Recovery pings

    /// Post an "all clear" notification when a previously-critical
    /// diagnosis resolves. Off by default — some users find these
    /// unnecessary, and the escalation pings alone are informative.
    /// On for users who want to know their machine is safe again
    /// without checking the menu.
    static let defaultNotifyOnRecovery = false

    static var notifyOnRecovery: Bool {
        UserDefaults.standard.object(forKey: Key.notifyOnRecovery) as? Bool
            ?? defaultNotifyOnRecovery
    }

    // MARK: - Density

    /// Compact vs detailed menu rendering. Default `false` (detailed) so
    /// existing users don't see a UI change without opting in. Compact
    /// mode drops duration/trend badges, tightens process rows, and caps
    /// the Top-processes list to 4 rows — meaningfully shorter menu.
    /// Show the Developer section even when no Docker/Harbr is detected.
    static var alwaysShowDeveloper: Bool {
        UserDefaults.standard.bool(forKey: Key.alwaysShowDeveloper)
    }

    static let defaultCompactMode = false

    static var compactMode: Bool {
        UserDefaults.standard.object(forKey: Key.compactMode) as? Bool
            ?? defaultCompactMode
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
