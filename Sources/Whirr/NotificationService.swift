import Foundation
import UserNotifications
import WhirrCore

/// Posts a macOS notification when a *new* critical diagnosis appears.
/// Edge-triggered via `DiagnosisChangeTracker` — a diagnosis that stays
/// critical for an hour produces exactly one notification.
@MainActor
final class NotificationService {
    private var tracker = DiagnosisChangeTracker()
    private var authorizationGranted = false

    init() {
        Task { await requestAuthorizationIfNeeded() }
    }

    func process(_ diagnoses: [Diagnosis]) {
        let newlyCritical = tracker.newlyCritical(in: diagnoses)
        guard !newlyCritical.isEmpty, authorizationGranted else { return }
        for diagnosis in newlyCritical {
            post(diagnosis)
        }
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
