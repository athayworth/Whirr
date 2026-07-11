import Foundation
import Observation

/// Persisted per-diagnosis snooze state. Users click "snooze" on a
/// diagnosis row and it stays hidden from the primary UI + severity
/// summary + notifications until the wall-clock timestamp elapses.
///
/// **Identity**: diagnosis title. Matches DiagnosisChangeTracker; a
/// snoozed title stays snoozed regardless of severity shifts or detail
/// text changes. If the user snoozes "Memory is tight" and it escalates
/// to "Memory is saturated," the escalation surfaces (different title)
/// but the tight-memory card stays hidden.
///
/// **Persistence**: UserDefaults. Snoozes are a user preference by
/// nature; sits alongside `Preferences`. The stored value is a dict of
/// `title → expiry ISO8601 string`, which is trivially JSON-encodable
/// via PropertyListEncoder without introducing a codable-Date pitfall.
///
/// **State model**: @Observable so SwiftUI views re-render when the user
/// snoozes/unsnoozes without an explicit binding.
@MainActor
@Observable
public final class SnoozeStore {
    public static let userDefaultsKey = "preferences.snoozedDiagnoses.v1"

    /// Backing dictionary. Titles map to expiry dates. Purged of expired
    /// entries on read + on write, so callers can trust that any key
    /// present has an active snooze.
    private var snoozes: [String: Date] = [:]

    /// Fixed snooze duration offered in the UI. One hour matches the
    /// most-common "come back after lunch" cadence and matches the
    /// notification cooldown's max value. `nonisolated` so it can serve
    /// as a default parameter value without crossing actor isolation.
    public nonisolated static let defaultDuration: TimeInterval = 3600

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        loadFromDefaults()
    }

    private let userDefaults: UserDefaults

    /// True if `title` currently has an active snooze.
    public func isSnoozed(_ title: String, at now: Date = Date()) -> Bool {
        guard let until = snoozes[title] else { return false }
        if until <= now {
            // Expired — purge lazily so callers don't have to remember to
            // clean up. Doing this here means snoozes decay naturally.
            snoozes.removeValue(forKey: title)
            persist()
            return false
        }
        return true
    }

    /// Returns the expiry date for `title` if currently snoozed. Useful
    /// for showing "snoozed for 42 more minutes" in the UI.
    public func snoozeExpiry(_ title: String, at now: Date = Date()) -> Date? {
        guard isSnoozed(title, at: now) else { return nil }
        return snoozes[title]
    }

    /// Extend the snooze on `title` by `duration` (or start one). Idempotent
    /// — repeat snoozes just push the expiry forward.
    public func snooze(_ title: String, duration: TimeInterval = SnoozeStore.defaultDuration, at now: Date = Date()) {
        snoozes[title] = now.addingTimeInterval(duration)
        persist()
    }

    public func unsnooze(_ title: String) {
        snoozes.removeValue(forKey: title)
        persist()
    }

    /// All currently-active snoozes, purged of expired ones. Consumed by
    /// the Snoozed section in the menu.
    public func active(at now: Date = Date()) -> [(title: String, until: Date)] {
        let live = snoozes.filter { $0.value > now }
        if live.count != snoozes.count {
            snoozes = live
            persist()
        }
        return live
            .sorted { $0.value < $1.value }
            .map { (title: $0.key, until: $0.value) }
    }

    private func loadFromDefaults() {
        // Stored as [String: Date] using PropertyListEncoder because
        // UserDefaults handles Date natively. Any decode failure resets
        // to empty — snooze state is fully non-critical.
        guard let raw = userDefaults.dictionary(forKey: Self.userDefaultsKey) else { return }
        var parsed: [String: Date] = [:]
        for (key, value) in raw {
            if let date = value as? Date { parsed[key] = date }
        }
        // Drop any expired entries at load time.
        let now = Date()
        snoozes = parsed.filter { $0.value > now }
    }

    private func persist() {
        // Store as a plain dictionary so it's inspectable in `defaults
        // read`. UserDefaults handles Date-in-dict without extra work.
        let asAny: [String: Any] = snoozes.reduce(into: [:]) { acc, entry in
            acc[entry.key] = entry.value
        }
        userDefaults.set(asAny, forKey: Self.userDefaultsKey)
    }
}
