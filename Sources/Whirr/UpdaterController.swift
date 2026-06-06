import Foundation
import Sparkle

/// Wraps Sparkle's `SPUStandardUpdaterController` in something the rest
/// of the app can observe. Sparkle reads its config from Info.plist
/// (`SUFeedURL`, `SUPublicEDKey`) at startup — see the keys in
/// Sources/Whirr/Resources/Info.plist and the release workflow notes
/// in README.md.
///
/// The controller is initialized with `startingUpdater: true`, which
/// schedules Sparkle's automatic background check. The first check
/// fires shortly after launch; subsequent checks run on Sparkle's
/// default cadence (weekly).
@MainActor
final class UpdaterController: ObservableObject {
    /// Published mirror of `updater.canCheckForUpdates`. Lets the
    /// "Check for Updates…" button disable itself while Sparkle is
    /// already mid-check.
    @Published private(set) var canCheckForUpdates: Bool = false

    let controller: SPUStandardUpdaterController

    init() {
        // Only start the background scheduler when SUFeedURL points at a
        // real host. With the placeholder URL still in place (local dev
        // before the activation steps in TODO.md), Sparkle would hit
        // YOUR_DOMAIN at its first scheduled check, fail to resolve, and
        // pop up an "Unable to Check For Updates" modal on the user.
        // Starting only when configured silences that path until the
        // appcast URL is real.
        let isConfigured = Self.hasConfiguredFeedURL()
        self.controller = SPUStandardUpdaterController(
            startingUpdater: isConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // KVO bridge: Sparkle exposes `canCheckForUpdates` as @objc
        // dynamic; mirror it into a @Published so SwiftUI views
        // disable correctly while a check is in flight.
        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Read SUFeedURL directly from the bundle Info.plist (the same key
    /// Sparkle reads) and reject the placeholder. Used both at init to
    /// decide whether to start the scheduler and at the menu level to
    /// decide whether to surface the manual button.
    private static func hasConfiguredFeedURL() -> Bool {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !raw.isEmpty,
              !raw.contains("YOUR_DOMAIN")
        else { return false }
        return true
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// True when the bundle has a Sparkle feed URL configured. We use
    /// this to surface a "not yet configured" hint in the Settings panel
    /// during local dev — before a real appcast URL is in Info.plist
    /// the button would just bounce.
    var hasFeedURL: Bool {
        Self.hasConfiguredFeedURL()
    }
}
