import SwiftUI
import WhirrCore

struct ConnectionSection: View {
    @Bindable var monitor: SystemMonitor

    var body: some View {
        SectionPage(title: "Connection") {
            SectionHeader(title: "Findings")
            FindingsList(monitor: monitor, area: .connection, emptyText: "Your connection looks healthy.")
        }
    }
}
