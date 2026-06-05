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
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
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

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// True when the bundle has a Sparkle feed URL configured. We use
    /// this to surface a "not yet configured" hint in the Settings panel
    /// during local dev — before a real appcast URL is in Info.plist
    /// the button would just bounce.
    var hasFeedURL: Bool {
        guard let url = controller.updater.feedURL else { return false }
        // The placeholder URL is the unmistakable "TODO" form; treat it
        // as not configured even though Sparkle technically has a value.
        return !url.absoluteString.contains("YOUR_DOMAIN")
    }
}
