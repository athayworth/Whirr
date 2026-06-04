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
        // Short-circuit when the user has turned notifications off — saves
        // both the tracker work and the system-authorization round-trip.
        guard Preferences.notificationsEnabled else { return }
        rebuildTrackerIfCooldownChanged()
        let newlyCritical = tracker.newlyCritical(in: diagnoses)
        guard !newlyCritical.isEmpty, authorizationGranted else { return }
        for diagnosis in newlyCritical {
            post(diagnosis)
        }
    }

    private func rebuildTrackerIfCooldownChanged() {
        let current = Preferences.notificationCooldownSeconds
        guard current != trackerCooldown else { return }
        trackerCooldown = current
        tracker = DiagnosisChangeTracker(cooldown: current)
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
        content.title = "Whirr — \(diagnosis.title)"
        content.body = diagnosis.detail
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
