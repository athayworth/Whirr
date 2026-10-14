import SwiftUI
import WhirrCore

/// Docker, dev servers and developer findings — out of the way for
/// everyone else.
struct DeveloperSection: View {
    @Bindable var monitor: SystemMonitor

    var body: some View {
        SectionPage(title: "Developer") {
            FindingsList(monitor: monitor, area: .developer, emptyText: "Nothing developer-related to report.")
            if !monitor.dockerContainers.isEmpty {
                SectionHeader(title: "Docker containers")
                VStack(alignment: .leading, spacing: 4) {
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
            if !monitor.harbrStatuses.isEmpty {
                SectionHeader(title: "Dev servers")
                HarbrSection(statuses: monitor.harbrStatuses)
            }
        }
    }
}
