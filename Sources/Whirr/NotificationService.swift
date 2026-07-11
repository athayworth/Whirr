import Foundation
import UserNotifications
import WhirrCore

/// Posts a macOS notification when a *new* critical diagnosis appears.
/// Edge-triggered via `DiagnosisChangeTracker` — a diagnosis that stays
/// critical for an hour produces exactly one notification.
///
/// The cooldown duration is read live from `Preferences` each call, so
/// the user can tune it from Settings without restarting the app. The
/// tracker is rebuilt only when the cooldown actually changes — its
/// internal state (cooldownUntil dictionary) survives identical-cooldown
/// calls so a value re-read on every tick doesn't reset flap suppression.
@MainActor
final class NotificationService {
    private var tracker: DiagnosisChangeTracker
    private var trackerCooldown: TimeInterval
    private var authorizationGranted = false

    init() {
        let initialCooldown = Preferences.notificationCooldownSeconds
        self.trackerCooldown = initialCooldown
        self.tracker = DiagnosisChangeTracker(cooldown: initialCooldown)
        Task { await requestAuthorizationIfNeeded() }
    }

    func process(_ diagnoses: [Diagnosis]) {
        guard Preferences.notificationsEnabled else { return }
        rebuildTrackerIfCooldownChanged()
        // Recovery pings look at the PRE-mutation state (titles that
        // were critical last tick and aren't now), so we compute them
        // BEFORE calling `newlyCritical` — which mutates
        // previousCriticalKeys.
        let clearedTitles = Preferences.notifyOnRecovery
            ? tracker.newlyCleared(in: diagnoses)
            : []
        let newlyCritical = tracker.newlyCritical(in: diagnoses)
        guard authorizationGranted else { return }
        for diagnosis in newlyCritical {
            post(diagnosis)
        }
        for title in clearedTitles {
            postRecovery(title: title)
        }
    }

    private func rebuildTrackerIfCooldownChanged() {
        let current = Preferences.notificationCooldownSeconds
        guard current != trackerCooldown else { return }
        trackerCooldown = current
        // Migrate the flap-suppression state so a preference change
        // doesn't let the user bypass cooldowns by toggling twice.
        tracker = DiagnosisChangeTracker(cooldown: current, migrating: tracker.snapshot)
    }

    private func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            authorizationGranted = true
        case .denied:
            authorizationGranted = false
        case .notDetermined:
            do {
                authorizationGranted = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                authorizationGranted = false
            }
        @unknown default:
            authorizationGranted = false
        }
    }

    private func post(_ diagnosis: Diagnosis) {
        let content = UNMutableNotificationContent()
        // App name is already surfaced by macOS in the notification's
        // icon strip; putting it in the title reads as boilerplate
        // ("Whirr — Whirr — Memory is saturated"). Keep the title tight
        // and use subtitle/body for context.
        content.title = diagnosis.title
        if let subtitle = subtitle(for: diagnosis) {
            content.subtitle = subtitle
        }
        content.body = diagnosis.detail
        content.sound = .default
        // Critical diagnoses should surface even when the user has
        // Focus/Do Not Disturb on — this is the whole point of an
        // alert for the memory-saturated case. Warnings stay at
        // `.active` so Focus can suppress them.
        content.interruptionLevel = diagnosis.severity == .critical ? .timeSensitive : .active
        // Same title → same notification thread. Successive escalations
        // of the same rule update the existing notification rather than
        // stacking a fresh one on the Notification Center every time.
        content.threadIdentifier = diagnosis.title
        let request = UNNotificationRequest(
            identifier: diagnosis.title,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// One-line action hint above the full body. Delegates to the
    /// WhirrCore-side subtitle mapping so the copy is testable in
    /// isolation (the executable target has no XCTest fixtures).
    private func subtitle(for diagnosis: Diagnosis) -> String? {
        NotificationSubtitles.subtitle(for: diagnosis.title)
    }

    /// "All clear" notification for a resolved critical. Same thread as
    /// the escalation ping so it *replaces* rather than stacks — the
    /// user sees one notification "Memory is saturated → resolved"
    /// rather than two conflicting ones.
    private func postRecovery(title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Resolved: \(title)"
        content.subtitle = "The condition has cleared."
        content.body = "Whirr will keep watching — you're safe to keep going."
        content.sound = nil  // recovery is not urgent — silent
        content.interruptionLevel = .active
        content.threadIdentifier = title
        let request = UNNotificationRequest(
            identifier: "\(title).recovery",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
