import SwiftUI
import WhirrCore

/// Re-launching Whirr while it's running (Spotlight, Launchpad, Finder)
/// opens the main window — the standard Mac answer to "where did the
/// app go?" for a menu bar app.
final class WhirrAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .whirrOpenMainWindow, object: nil)
        return false
    }
}

@main
struct WhirrApp: App {
    static let mainWindowID = "main"
    @NSApplicationDelegateAdaptor(WhirrAppDelegate.self) private var appDelegate

    @State private var monitor = SystemMonitor()
    /// Sparkle bridge — owns the SPUStandardUpdaterController so the
    /// auto-update scheduler starts at launch. Injected into Settings
    /// so the About tab can drive a manual "Check for Updates…" button
    /// off the same instance.
    @StateObject private var updater = UpdaterController()

    init() {
        // Show the first-run onboarding window if the user hasn't
        // finished it yet. Async to next runloop tick so NSApp is
        // fully constructed before we ask it to activate.
        DispatchQueue.main.async {
            OnboardingWindowController.shared.showIfNeeded()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPopoverView(monitor: monitor)
        } label: {
            MenuBarFanIcon(severity: monitor.worstSeverity)
        }
        .menuBarExtraStyle(.window)

        Window("Whirr", id: Self.mainWindowID) {
            MainWindow(monitor: monitor)
        }
        .defaultSize(width: 900, height: 640)

        // Standard macOS Settings panel — opened from the menu's
        // "Settings…" button via `@Environment(\.openSettings)`. Bound
        // to @AppStorage; SystemMonitor / NotificationService read live
        // values on each tick so changes take effect on the next sample.
        Settings {
            SettingsView(
                updater: updater,
                rulesLoadResult: monitor.rulesConfigLoadResult,
                incidentLog: monitor.incidentLog,
                snoozeStore: monitor.snoozeStore
            )
        }
    }
}

/// Menu bar label icon. The fan signals severity through color + fill +
/// a built-in SF Symbol pulse — *not* a SwiftUI animation. A continuous
/// SwiftUI animation here (TimelineView, withAnimation) forces the status
/// item to re-rasterize every frame and pegs CPU near 100%; the native
/// `.symbolEffect` runs inside the SF Symbols renderer instead and is
/// effectively free.
private struct MenuBarFanIcon: View {
    let severity: Severity
    /// The label is the one view that always exists, so it's where
    /// non-SwiftUI callers (actions, onboarding) can reach `openWindow`.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        icon
            .onReceive(NotificationCenter.default.publisher(for: .whirrOpenMainWindow)) { _ in
                openWindow(id: WhirrApp.mainWindowID)
                NSApp.activate(ignoringOtherApps: true)
            }
    }

    private var icon: some View {
        Image(systemName: symbolName)
            .foregroundStyle(tint)
            .symbolEffect(
                .variableColor.iterative.reversing,
                options: .repeating,
                isActive: severity != .ok
            )
    }

    private var symbolName: String {
        severity == .critical ? "fanblades.fill" : "fanblades"
    }

    private var tint: Color {
        switch severity {
        case .ok:       return .primary
        case .warning:  return .yellow
        case .critical: return .red
        }
    }
}
