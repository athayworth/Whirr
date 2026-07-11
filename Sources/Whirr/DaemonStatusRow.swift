import SwiftUI

/// Inline row that surfaces the SMAppService daemon's state.
///
/// **Rendering strategy**: actionable states (offer to enable, approve,
/// retry) get the full row so the button is prominent. The one
/// non-actionable case — `.notFound` under ad-hoc signing, which the
/// user cannot fix from Whirr — renders as `EmptyView()`. That state
/// still surfaces as a compact info-icon in the footer via
/// `DaemonStatusHint`, so anyone curious can hover for the explanation
/// without it dominating a 60 pt slice of the menu on every open.
struct DaemonStatusRow: View {
    let daemon: DaemonManager

    var body: some View {
        switch daemon.state {
        case .enabled:
            // Silent success — no UI noise when the daemon is doing its job.
            EmptyView()

        case .notRegistered:
            advisoryRow(
                icon: "shield.lefthalf.filled",
                iconColor: .secondary,
                title: "Advanced sampling is off",
                detail: "Enable to see root processes (WindowServer, backupd, mds_stores).",
                actionLabel: "Enable",
                action: { daemon.register() }
            )

        case .requiresApproval:
            advisoryRow(
                icon: "person.badge.shield.checkmark",
                iconColor: .orange,
                title: "Approve in System Settings",
                detail: "macOS requires explicit consent before background daemons start.",
                actionLabel: "Open Settings",
                action: { daemon.openSettings() }
            )

        case .notFound:
            // Non-actionable under ad-hoc signing. Deferred to the footer
            // hint so it doesn't dominate every menu open with three
            // lines of unfixable-for-you copy.
            EmptyView()

        case .error(let message):
            advisoryRow(
                icon: "exclamationmark.triangle",
                iconColor: .red,
                title: "Daemon error",
                detail: message,
                actionLabel: "Retry",
                action: { daemon.register() }
            )
        }
    }

    /// `.notFound` surfaces in two distinct situations. Pick the more
    /// useful explanation by checking whether we're running inside a real
    /// `.app` bundle: if we are, the bundle is fine and SMAppService is
    /// refusing the daemon for another reason (most commonly: ad-hoc
    /// code signing — SMAppService requires Developer ID).
    private var notFoundDetail: String {
        let runningFromBundle = Bundle.main.bundlePath.hasSuffix(".app")
        if runningFromBundle {
            return "macOS requires Developer ID signing for the bundled "
                + "daemon. This build is ad-hoc signed — Whirr is sampling "
                + "your own processes only."
        }
        return "Run dist/Whirr.app for the bundled daemon path."
    }

    /// True when the current daemon state produces no advisory row —
    /// used by MenuBarView to decide whether to render the divider
    /// above it. Prevents an orphan divider when the row itself is
    /// hidden (`.enabled` and `.notFound`).
    var producesRow: Bool {
        switch daemon.state {
        case .enabled, .notFound: return false
        case .notRegistered, .requiresApproval, .error: return true
        }
    }

    @ViewBuilder
    private func advisoryRow(
        icon: String,
        iconColor: Color,
        title: String,
        detail: String,
        actionLabel: String?,
        action: (() -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Compact icon-with-tooltip for the footer. Renders the same daemon
/// state advice the row would, but shrunk to a small badge that lives
/// next to the RAM/swap line. Used specifically for the `.notFound`
/// (ad-hoc signing) state — advisory-row-worthy would be too loud, but
/// hiding it entirely means the curious user can't find out why.
struct DaemonStatusHint: View {
    let daemon: DaemonManager

    var body: some View {
        if case .notFound = daemon.state {
            Image(systemName: "shield")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help(notFoundDetail)
                .accessibilityLabel("Advanced sampling unavailable")
                .accessibilityHint(notFoundDetail)
        }
    }

    /// Matches the copy the full row used to show — kept identical so
    /// the tooltip is the *only* place this explanation lives (single
    /// source of truth for the ad-hoc-signing story).
    private var notFoundDetail: String {
        let runningFromBundle = Bundle.main.bundlePath.hasSuffix(".app")
        if runningFromBundle {
            return "Advanced sampling requires Developer ID signing for the bundled daemon. "
                + "This build is ad-hoc signed — Whirr is sampling your own processes only."
        }
        return "Run dist/Whirr.app for the bundled daemon path."
    }
}
