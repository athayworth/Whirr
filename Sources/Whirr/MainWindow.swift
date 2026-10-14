import AppKit
import SwiftUI
import WhirrCore

/// The main window: sidebar of sections, each answering one question.
struct MainWindow: View {
    @Bindable var monitor: SystemMonitor

    var body: some View {
        NavigationSplitView {
            List(selection: $monitor.selectedSection) {
                ForEach(visibleItems) { item in
                    HStack {
                        Label(item.title, systemImage: item.symbol)
                        Spacer()
                        if let area = item.area, let severity = monitor.verdict.areaSeverity[area] {
                            StatusDot(severity: severity)
                        }
                    }
                    .tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            switch monitor.selectedSection ?? .overview {
            case .overview: OverviewSection(monitor: monitor)
            case .mac: MacSection(monitor: monitor)
            case .connection: ConnectionSection(monitor: monitor)
            case .history: HistorySectionView(monitor: monitor)
            case .developer: DeveloperSection(monitor: monitor)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .sheet(item: $monitor.presentedHowTo) { howTo in
            HowToSheet(howTo: howTo, gatewayIP: monitor.gatewayIP)
        }
        // Show in the Dock / Cmd-Tab only while the window is open.
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    private var visibleItems: [SidebarItem] {
        SidebarItem.allCases.filter { $0 != .developer || monitor.isDeveloperRelevant }
    }
}
