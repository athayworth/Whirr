import SwiftUI
import WhirrCore

/// The menu bar popover: the one-sentence answer, the one action, the
/// other causes as single lines, and a way into the window.
struct MenuPopoverView: View {
    @Bindable var monitor: SystemMonitor
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var top: Story? { monitor.verdict.stories.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(severity: monitor.verdict.worst, sampled: monitor.hasSampledYet)
                Text(headline).font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            if let because = top?.because {
                Text(because).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let top, let action = top.action {
                if ActionText.needsConfirmation(action) {
                    // Confirmation dialogs belong in the window.
                    Button(action.label) { open(top) }
                        .buttonStyle(.borderedProminent).tint(monitor.verdict.worst.tint)
                } else {
                    Button(action.label) { monitor.perform(action) }
                        .buttonStyle(.borderedProminent).tint(monitor.verdict.worst.tint)
                }
            }
            let others = Array(monitor.verdict.stories.dropFirst())
            if !others.isEmpty {
                Divider()
                ForEach(others) { story in
                    Button { open(story) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Also: \(story.phrase)").font(.callout.weight(.medium))
                            if let because = story.because {
                                Text(because).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            Button {
                if let top { open(top) } else { showMainWindow() }
            } label: {
                Label(top == nil ? "Open Whirr…" : "Open Whirr → see why", systemImage: "macwindow")
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
        .frame(width: 320)
    }

    private var headline: String {
        guard monitor.hasSampledYet else { return "Checking…" }
        if let sentence = monitor.verdict.sentence { return sentence }
        if let pending = monitor.verdict.pendingStories.first {
            return "Keeping an eye on something — \(pending.phrase)."
        }
        return "All good right now."
    }

    private func open(_ story: Story) {
        monitor.nav.openStory(story)
        showMainWindow()
    }

    private func showMainWindow() {
        openWindow(id: WhirrApp.mainWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}
