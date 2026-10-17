import Foundation

/// The Overview's answer to "what's wrong right now, and what do I do?"
public struct Verdict: Sendable, Equatable {
    /// Problem stories past the gate, most important first.
    public let stories: [Story]
    /// Problem stories still inside the gate — not loud yet, but "all
    /// clear" would be a false reassurance while they exist.
    public let pendingStories: [Story]
    /// Stories whose headline is a note.
    public let notes: [Story]
    /// Worst gated-story severity per sidebar area. Missing = fine.
    public let areaSeverity: [Diagnosis.Area: Severity]
    /// "Your Mac is overloaded, and your link to the router is stalling."
    public let sentence: String?

    public var headline: DiagnosisContext? { stories.first?.headline }
    public var also: [DiagnosisContext] { stories.dropFirst().map(\.headline) }
    public var pending: [DiagnosisContext] { pendingStories.map(\.headline) }
    public var worst: Severity { areaSeverity.values.max() ?? .ok }
    public var isAllClear: Bool { stories.isEmpty && pendingStories.isEmpty }

    public static let allClear = Verdict(stories: [], pendingStories: [], notes: [], areaSeverity: [:], sentence: nil)

    public init(stories: [Story], pendingStories: [Story], notes: [Story],
                areaSeverity: [Diagnosis.Area: Severity], sentence: String?) {
        self.stories = stories
        self.pendingStories = pendingStories
        self.notes = notes
        self.areaSeverity = areaSeverity
        self.sentence = sentence
    }

    /// Stories for one sidebar area: gated, then pending, then notes.
    public func stories(in area: Diagnosis.Area) -> [Story] {
        (stories + pendingStories + notes).filter { $0.area == area }
    }
}

/// Pure selection policy for the Overview headline, menu bar icon color
/// and notifications. One place decides what is loud.
public enum VerdictSelector {
    /// A problem must persist this long before it colors the icon or
    /// headlines — brief spikes (a build, a page load) stay quiet.
    public static let iconGateSeconds = 120
    /// A problem must persist this long before it can notify.
    public static let notifyGateSeconds = 300

    public static func select(
        _ contexts: [DiagnosisContext],
        isHidden: (String) -> Bool,
        load: OwnerLoad = .empty
    ) -> Verdict {
        // Hidden members drop out first, so a snoozed headline hands over
        // to a visible member of the same story.
        let visible = contexts.filter { !isHidden($0.diagnosis.title) }
        let all = StoryBuilder.build(visible, load: load)
        let problems = all.filter(\.isProblem)
        let gated = problems.filter { $0.durationSeconds >= iconGateSeconds }
        let pending = problems.filter { $0.durationSeconds < iconGateSeconds }
        var areaSeverity: [Diagnosis.Area: Severity] = [:]
        for s in gated {
            areaSeverity[s.area] = max(areaSeverity[s.area] ?? .ok, s.headline.diagnosis.severity)
        }
        return Verdict(stories: gated, pendingStories: pending, notes: all.filter { !$0.isProblem },
                       areaSeverity: areaSeverity, sentence: StoryBuilder.sentence(gated))
    }

    /// Peak severity in the current streak (so a problem dipping
    /// critical→warning→critical doesn't flap the headline), then
    /// duration (the long-running problem is the one the user is
    /// feeling), then narratives (they explain several signals at once),
    /// then title so the order is deterministic tick to tick.
    static func isMoreImportant(_ a: DiagnosisContext, _ b: DiagnosisContext) -> Bool {
        if a.peakSeverity != b.peakSeverity { return a.peakSeverity > b.peakSeverity }
        if a.durationSeconds != b.durationSeconds { return a.durationSeconds > b.durationSeconds }
        let aNarrative = a.diagnosis.kind == .narrative
        let bNarrative = b.diagnosis.kind == .narrative
        if aNarrative != bNarrative { return aNarrative }
        return a.diagnosis.title < b.diagnosis.title
    }

    /// Notifications are reserved for problems that are critical, have
    /// lasted at least five minutes, and come with something to do.
    public static func shouldNotify(_ story: Story) -> Bool {
        story.isProblem
            && story.headline.diagnosis.severity == .critical
            && story.durationSeconds >= notifyGateSeconds
            && story.action != nil
    }

    public static func shouldNotify(_ c: DiagnosisContext) -> Bool {
        c.diagnosis.tier == .problem
            && c.diagnosis.severity == .critical
            && c.durationSeconds >= notifyGateSeconds
            && c.diagnosis.action != nil
    }
}
