import SwiftUI
import WhirrCore

/// The menu bar popover: the headline and a way into the window.
/// Everything else lives in the main window.
struct MenuPopoverView: View {
    @Bindable var monitor: SystemMonitor
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(severity: monitor.verdict.worst, sampled: monitor.hasSampledYet)
                Text(headline).font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            if let detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            if let action = monitor.verdict.headline?.diagnosis.action, !ActionText.needsConfirmation(action) {
                Button(action.label) { monitor.perform(action) }
                    .buttonStyle(.borderedProminent)
                    .tint(monitor.verdict.worst.tint)
            }
            Divider()
            Button {
                showMainWindow()
            } label: {
                Label("Open Whirr…", systemImage: "macwindow")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("o")
            HStack {
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                .keyboardShortcut(",")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300)
    }

    private var headline: String {
        guard monitor.hasSampledYet else { return "Checking…" }
        if let headline = monitor.verdict.headline { return headline.diagnosis.title }
        return monitor.verdict.pending.isEmpty ? "Everything's running smoothly" : "Keeping an eye on something…"
    }

    private var detail: String? {
        guard monitor.hasSampledYet else { return nil }
        guard monitor.verdict.headline != nil else {
            return monitor.verdict.pending.isEmpty ? nil
                : "Something just changed. Whirr waits a couple of minutes before raising it, so brief blips stay quiet."
        }
        let more = monitor.verdict.also.count
        return more > 0 ? "Plus \(more) more — open Whirr for details." : nil
    }

    private func showMainWindow() {
        openWindow(id: WhirrApp.mainWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}
