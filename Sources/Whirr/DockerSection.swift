import SwiftUI
import WhirrCore

/// Header + member rows for one group of related containers. Members
/// for projects show indented under the group header with the compose
/// service name; ungrouped containers show flat without a header.
struct DockerGroupView: View {
    let group: DockerContainerGroup
    @Binding var expandedContainer: String?
    let dockerClient: DockerClient

    @State private var inFlight: String? = nil
    @State private var lastError: String? = nil
    @State private var pendingAction: GroupAction? = nil
    @State private var showingConfirm: Bool = false

    private enum GroupAction { case stop, restart }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let project = group.project {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(project)
                        .font(.callout.weight(.medium))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(group.members.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let inFlight {
                        Text(inFlight)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(MenuFormat.bytes(group.totalMemoryBytes))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Menu {
                        Button("Restart all (\(group.members.count) containers)") {
                            pendingAction = .restart
                            showingConfirm = true
                        }
                        Button("Stop all (\(group.members.count) containers)") {
                            pendingAction = .stop
                            showingConfirm = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.callout)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(inFlight != nil)
                }
            }
            if let lastError {
                Text(lastError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            ForEach(group.members) { container in
                DockerContainerRow(
                    container: container,
                    indented: group.project != nil,
                    expandedContainer: $expandedContainer,
                    dockerClient: dockerClient
                )
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: $showingConfirm, presenting: pendingAction) { action in
            Button(action == .stop ? "Stop \(group.members.count) containers" : "Restart \(group.members.count) containers",
                   role: .destructive) {
                performGroupAction(action)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var confirmationTitle: String {
        guard let project = group.project else { return "Confirm" }
        switch pendingAction {
        case .stop:    return "Stop all containers in \(project)?"
        case .restart: return "Restart all containers in \(project)?"
        case .none:    return ""
        }
    }

    private func performGroupAction(_ action: GroupAction) {
        let verbing = action == .stop ? "Stopping…" : "Restarting…"
        inFlight = verbing
        lastError = nil
        let containers = group.members
        Task {
            do {
                try await withThrowingTaskGroup(of: Void.self) { tg in
                    for container in containers {
                        tg.addTask {
                            switch action {
                            case .stop:    try await dockerClient.stop(containerId: container.id)
                            case .restart: try await dockerClient.restart(containerId: container.id)
                            }
                        }
                    }
                    try await tg.waitForAll()
                }
                inFlight = nil
            } catch {
                inFlight = nil
                lastError = "Action failed: \(error)"
            }
        }
    }
}

private struct DockerContainerRow: View {
    let container: DockerContainer
    let indented: Bool
    @Binding var expandedContainer: String?
    let dockerClient: DockerClient

    private var isExpanded: Bool { expandedContainer == container.id }
    private var displayName: String {
        // When inside a compose project the service name ("db") reads better
        // than the full container name ("supabase_db_pants-admin").
        container.composeService ?? container.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expandedContainer = isExpanded ? nil : container.id
            } label: {
                HStack(spacing: 8) {
                    if indented { Spacer().frame(width: 14) }
                    Text(displayName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if container.cpuPercent >= 1 {
                        Text(String(format: "%.0f%%", container.cpuPercent))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Text(MenuFormat.bytes(container.memoryBytes))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                DockerContainerDetail(container: container, dockerClient: dockerClient)
                    .padding(.leading, indented ? 14 : 0)
            }
        }
    }
}

private struct DockerContainerDetail: View {
    let container: DockerContainer
    let dockerClient: DockerClient
    @State private var inFlight: String? = nil
    @State private var lastError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                detailRow("id", container.id)
                detailRow("name", container.name)
                detailRow("image", container.image)
                if let status = container.status {
                    detailRow("status", status)
                }
                if let project = container.composeProject {
                    detailRow("project", project)
                }
                if let limit = container.memoryLimitBytes, limit > 0 {
                    let pct = Double(container.memoryBytes) / Double(limit) * 100
                    detailRow("limit", "\(MenuFormat.bytes(limit)) (\(Int(pct))% used)")
                }
            }

            HStack(spacing: 8) {
                Button("Stop") { perform("Stop") { try await dockerClient.stop(containerId: container.id) } }
                    .controlSize(.small)
                    .disabled(inFlight != nil)
                    .help("Sends SIGTERM to the container's main process. Equivalent to `docker stop`.")
                Button("Restart") { perform("Restart") { try await dockerClient.restart(containerId: container.id) } }
                    .controlSize(.small)
                    .disabled(inFlight != nil)
                Spacer()
                if let inFlight {
                    Text("\(inFlight)…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let lastError {
                    Text(lastError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private func perform(_ action: String, _ block: @escaping () async throws -> Void) {
        inFlight = action
        lastError = nil
        Task {
            do {
                try await block()
                inFlight = nil
            } catch {
                inFlight = nil
                lastError = "\(action) failed: \(error)"
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)
            Text(value)
                .font(.caption2)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
