import SwiftUI
import AppKit

/// First-run welcome flow. Shown once — dismiss sets
/// `Preferences.hasCompletedOnboarding` so it never reappears.
///
/// Three short "cards" that swipe left-to-right:
///   1. What Whirr is
///   2. Where the menu bar icon lives + what the verdict means
///   3. How diagnoses / snooze / insights work
///
/// Deliberately short — a menu bar utility that gates itself on a
/// 15-page tutorial is user-hostile.
struct OnboardingView: View {
    let onDismiss: () -> Void

    @State private var page: Int = 0
    private static let totalPages = 3

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                page0.tag(0)
                page1.tag(1)
                page2.tag(2)
            }
            .tabViewStyle(.automatic)
            .frame(minHeight: 320)

            Divider()

            HStack(spacing: 10) {
                // Progress dots — tap to jump between pages. Keeps the
                // flow discoverable without adding a separate progress bar.
                ForEach(0..<Self.totalPages, id: \.self) { index in
                    Circle()
                        .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .onTapGesture { withAnimation { page = index } }
                        .accessibilityHidden(true)
                }
                Spacer()
                if page > 0 {
                    Button("Back") { withAnimation { page -= 1 } }
                        .keyboardShortcut(.leftArrow)
                }
                Button(page == Self.totalPages - 1 ? "Get started" : "Next") {
                    if page < Self.totalPages - 1 {
                        withAnimation { page += 1 }
                    } else {
                        onDismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 420)
    }

    // MARK: - Page 1 — what Whirr is

    private var page0: some View {
        VStack(spacing: 16) {
            Spacer()
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            } else {
                Image(systemName: "fanblades.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.tint)
            }
            Text("Welcome to Whirr")
                .font(.largeTitle.bold())
            Text("Whirr tells you why your Mac is slow — before you have to guess. It watches memory, swap, CPU, disk, and the apps you're running, then says what to close (or leave alone).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Page 2 — the menu bar icon

    private var page1: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("It lives in your menu bar")
                .font(.title2.bold())
                .padding(.top, 8)
            Text("Look for the fanblade icon at the top of your screen. It reflects your Mac and your connection, and changes color only after a problem has lasted two minutes:")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                verdictRow(
                    icon: "fanblades",
                    color: .primary,
                    label: "Nothing needs attention",
                    description: "Whirr is watching. Background notes never change the icon."
                )
                verdictRow(
                    icon: "fanblades",
                    color: .yellow,
                    label: "Something needs attention",
                    description: "For example memory running low, or Wi-Fi stalling. Open Whirr to see what it measured."
                )
                verdictRow(
                    icon: "fanblades.fill",
                    color: .red,
                    label: "A serious problem",
                    description: "For example memory saturated, or the internet down. Whirr says what it saw and what you can do."
                )
            }
            .padding(.leading, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }

    private func verdictRow(icon: String, color: Color, label: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.title2)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.callout).bold()
                Text(description).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Page 3 — diagnoses, snooze, insights

    private var page2: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("A few things to know")
                .font(.title2.bold())
                .padding(.top, 8)

            featureRow(
                icon: "list.bullet.rectangle.portrait",
                title: "Findings say what Whirr measured",
                description: "Each finding names what Whirr saw — memory running low, Wi-Fi stalling, a process stuck at full CPU — and what you can do about it. Whirr only names a cause when its measurements show it."
            )
            featureRow(
                icon: "moon.zzz",
                title: "Quiet what you already know",
                description: "Use the ⋯ menu on a finding to snooze it for an hour, or choose \"This is normal for me\" to stop seeing it. Settings → Quieted lists everything you've quieted."
            )
            featureRow(
                icon: "book",
                title: "Learn as you go",
                description: "Not sure what a term means? Click any ⓘ, or open Learn in the sidebar for plain-English explanations."
            )
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }

    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .font(.title3)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).bold()
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Manages the onboarding window's lifecycle. Uses AppKit directly
/// because `@Environment(\.openWindow)` can't be called from
/// `App.init`, and creating a `Window` scene conditionally is fiddly.
///
/// Called once at app launch — if the user hasn't finished onboarding,
/// activate the app and open the window. On dismiss OR user-triggered
/// window close, mark completion + revert the activation policy so
/// Whirr goes back to being a menu-bar-only agent app.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?

    /// Present the onboarding window if the user hasn't finished it
    /// yet. Idempotent — repeat calls after completion do nothing.
    func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Preferences.Key.hasCompletedOnboarding) else {
            return
        }
        show()
    }

    /// Force-show the window (used from the About tab's "Show welcome
    /// again" button, if we add it later).
    func show() {
        if let existing = window {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let controller = NSHostingController(
            rootView: OnboardingView { [weak self] in self?.dismiss() }
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "Welcome to Whirr"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        // Observe close so a user who dismisses via the red traffic
        // light (rather than the "Get started" button) also gets the
        // activation policy reverted. Prior code only handled the
        // button dismiss — closing via the window chrome left the app
        // stuck in `.regular` and visible in the dock across launches.
        window.delegate = self
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    /// Explicit "Get started" dismiss: mark completion AND revert.
    private func dismiss() {
        UserDefaults.standard.set(true, forKey: Preferences.Key.hasCompletedOnboarding)
        window?.close()
        // Land the user in the main window, not just the menu bar.
        NotificationCenter.default.post(name: .whirrOpenMainWindow, object: nil)
    }

    // MARK: - NSWindowDelegate

    /// Called for any window close (button dismiss OR traffic-light OR
    /// programmatic close via `close()`). We revert the activation
    /// policy here so the "app is stuck in dock" failure mode can't
    /// happen regardless of how the user dismissed the window.
    /// Completion state is NOT set here — that's the "Get started"
    /// button's job; closing without finishing keeps onboarding
    /// available on the next launch.
    func windowWillClose(_ notification: Notification) {
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
