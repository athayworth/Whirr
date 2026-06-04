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
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
