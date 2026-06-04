import Foundation
import Observation
import ServiceManagement

/// Wraps `SMAppService.daemon` so the rest of the app sees a single
/// observable state machine instead of poking at the System Management API
/// directly. The daemon binary + plist live inside the app bundle (see
/// `Contents/Library/LaunchDaemons/com.athayworth.whirr.sampler.plist`);
/// registering it is what surfaces the "Allow background activity?" prompt
/// in System Settings.
///
/// SMAppService.daemon was introduced in macOS 13 and is the modern path
/// for shipping launchd-managed daemons inside an app bundle. The legacy
/// `sudo scripts/install-sampler.sh` flow still works, but it requires
/// admin rights at install time and isn't viable for non-technical users.
@MainActor
@Observable
final class DaemonManager {
    /// The plist filename inside `Contents/Library/LaunchDaemons/` that
    /// SMAppService resolves to find the daemon definition. Must match
    /// the file copied in by build.sh.
    static let plistName = "com.athayworth.whirr.sampler.plist"

    enum State: Equatable {
        /// Bundle has no daemon plist — typically because the app is being
        /// run via `swift run` instead of from `dist/Whirr.app`.
        case notFound
        /// Daemon is shipped in the bundle but hasn't been registered yet.
        /// Clicking Enable triggers registration.
        case notRegistered
        /// Registered, but macOS is waiting on the user to flip the toggle
        /// in System Settings → Login Items & Extensions.
        case requiresApproval
        /// Daemon is registered and approved — launchd is keeping it alive.
        case enabled
        /// Something went wrong during register/unregister. The captured
        /// message is whatever NSError surfaced and is rendered as-is.
        case error(String)
    }

    private(set) var state: State = .notRegistered
    private let daemon: SMAppService

    init() {
        self.daemon = SMAppService.daemon(plistName: Self.plistName)
        refresh()
    }

    /// Re-read the daemon's status from the system. Call after register /
    /// unregister, and after returning to the foreground — the user may
    /// have flipped the System Settings toggle while we weren't looking.
    func refresh() {
        state = Self.map(daemon.status)
    }

    /// Register the daemon. The first call (per user) surfaces the macOS
    /// approval prompt; subsequent calls when already approved are no-ops.
    /// Errors bubble up via `state = .error(message)`.
    func register() {
        do {
            try daemon.register()
            refresh()
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Unregister the daemon. macOS stops the running process and clears
    /// the user-visible Login Items entry.
    func unregister() async {
        do {
            try await daemon.unregister()
            refresh()
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Pops open System Settings → Login Items & Extensions so the user
    /// can flip the toggle when `state == .requiresApproval`.
    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func map(_ status: SMAppService.Status) -> State {
        switch status {
        case .notFound:          return .notFound
        case .notRegistered:     return .notRegistered
        case .requiresApproval:  return .requiresApproval
        case .enabled:           return .enabled
        @unknown default:        return .error("Unknown SMAppService status")
        }
    }
}
