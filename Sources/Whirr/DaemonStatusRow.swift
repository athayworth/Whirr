import SwiftUI

/// Single inline row that surfaces the SMAppService daemon's state. Silent
/// when everything's working (`enabled`); otherwise shows what the user
/// needs to do (enable, approve, or fix). Lives just above the menu's
/// footer so it's always visible without scrolling.
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
            // Running via `swift run` instead of from the .app bundle —
            // there's no plist on disk for SMAppService to register.
            advisoryRow(
                icon: "exclamationmark.shield",
                iconColor: .secondary,
                title: "Advanced sampling unavailable",
                detail: "Run dist/Whirr.app for the bundled daemon path.",
                actionLabel: nil,
                action: nil
            )

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
