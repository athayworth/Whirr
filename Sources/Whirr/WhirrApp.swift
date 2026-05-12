import SwiftUI

@main
struct WhirrApp: App {
    @State private var monitor = SystemMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(monitor: monitor)
        } label: {
            Image(systemName: monitor.statusIcon)
        }
        .menuBarExtraStyle(.window)
    }
}
