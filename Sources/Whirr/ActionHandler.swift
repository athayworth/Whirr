import AppKit
import SwiftUI
import WhirrCore

extension SuggestedAction.HowTo: Identifiable {
    public var id: String { rawValue }
}

/// Copy for confirming actions that stop or quit something.
enum ActionText {
    static func needsConfirmation(_ action: SuggestedAction) -> Bool {
        switch action.kind {
        case .stopDocker, .quitApp: return true
        default: return false
        }
    }

    static func confirmation(for action: SuggestedAction) -> String {
        switch action.kind {
        case .stopDocker:
            return "All running Docker containers will be stopped. Anything they were doing (dev servers, databases) stops until you start them again."
        case .quitApp:
            return "The app will be asked to quit. Unsaved work in it may be lost."
        default:
            return ""
        }
    }
}

extension SystemMonitor {
    /// Runs a finding's suggested action. Rules only describe actions;
    /// this is the one place they become side effects.
    func perform(_ action: SuggestedAction) {
        switch action.kind {
        case .quitApp(let pid):
            if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                app.terminate()
            } else {
                kill(pid_t(pid), SIGTERM)
            }
        case .stopDocker:
            Task { await stopAllDockerContainers() }
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .openSection(let area):
            selectedSection = SidebarItem.allCases.first { $0.area == area }
            requestMainWindow()
        case .runConnectionTest:
            selectedSection = .connection
            pendingConnectionTest = true
            requestMainWindow()
        case .showHowTo(let howTo):
            presentedHowTo = howTo
            requestMainWindow()
        }
    }

    /// Asks the scene layer to open/raise the main window. The menu bar
    /// label view listens for this (it's the one view that always
    /// exists and can reach `openWindow`).
    func requestMainWindow() {
        NotificationCenter.default.post(name: .whirrOpenMainWindow, object: nil)
    }
}

extension Notification.Name {
    static let whirrOpenMainWindow = Notification.Name("WhirrOpenMainWindow")
}
