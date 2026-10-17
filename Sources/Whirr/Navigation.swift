import Observation
import WhirrCore

/// Where the main window is and what it's showing on top.
@MainActor
@Observable
final class Navigation {
    /// Current main-window section. Shared so the menu popover and action
    /// buttons can jump the window to a section.
    var selectedSection: SidebarItem? = .overview
    /// How-to sheet currently shown over the main window.
    var presentedHowTo: SuggestedAction.HowTo?
    /// Set by actions that want the Connection section to start a test
    /// as soon as it appears.
    var pendingConnectionTest = false
    /// The story whose "Why?" should be open when its section appears.
    var focusedStoryID: String?

    /// Jumps to a story's section with its "Why?" open.
    func openStory(_ story: Story) {
        selectedSection = SidebarItem.allCases.first { $0.area == story.area } ?? .overview
        focusedStoryID = story.id
    }
}
