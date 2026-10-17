import SwiftUI
import WhirrCore

/// Docker, dev servers and developer findings — out of the way for
/// everyone else.
struct DeveloperSection: View {
    @Bindable var monitor: SystemMonitor

    var body: some View {
        SectionPage(title: "Developer") {
            AnswerCard(monitor: monitor, area: .developer)
            FindingsList(monitor: monitor, area: .developer)
            KeyFacts(facts: [
                ("Containers running", "\(monitor.dockerContainers.count)", nil),
                ("Docker memory", MenuFormat.bytes(monitor.dockerContainers.reduce(UInt64(0)) { $0 &+ $1.memoryBytes }), nil),
                ("Dev servers up", "\(monitor.harbrStatuses.filter(\.isRunning).count) of \(monitor.harbrStatuses.count)", nil),
            ])
            VStack(alignment: .leading, spacing: 4) {
                FoldRow("Containers", summary: "\(monitor.dockerContainers.count)", key: "developer.containers") {
                    VStack(alignment: .leading, spacing: 4) {
                        if monitor.dockerContainers.isEmpty { Text("No containers running.").foregroundStyle(.secondary) }
                        ForEach(DockerContainerGroup.group(monitor.dockerContainers)) { group in
                            DockerGroupView(
                                group: group,
                                expandedContainer: $monitor.expandedContainerId,
                                dockerClient: monitor.dockerClient,
                                history: monitor.dockerHistory
                            )
                        }
                    }
                }
                Divider()
                FoldRow("Dev servers", summary: "\(monitor.harbrStatuses.count)", key: "developer.servers") {
                    if monitor.harbrStatuses.isEmpty {
                        Text("No dev servers configured.").foregroundStyle(.secondary)
                    } else {
                        HarbrSection(statuses: monitor.harbrStatuses)
                    }
                }
            }
        }
    }
}
