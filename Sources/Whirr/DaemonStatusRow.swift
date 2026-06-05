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
            advisoryRow(
                icon: "exclamationmark.shield",
                iconColor: .secondary,
                title: "Advanced sampling unavailable",
                detail: notFoundDetail,
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
