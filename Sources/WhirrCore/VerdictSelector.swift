import Foundation

/// The Overview's answer to "what's the one thing wrong right now?"
public struct Verdict: Sendable, Equatable {
    /// The single most important problem, or nil when all clear.
    public let headline: DiagnosisContext?
    /// Other gated problems, most important first ("Also: …" lines).
    public let also: [DiagnosisContext]
    /// Worst gated-problem severity per sidebar area. Missing = fine.
    public let areaSeverity: [Diagnosis.Area: Severity]
    /// Visible problems still inside the gate. Not loud yet, but their
    /// presence means "all clear" would be a false reassurance — every
    /// problem is young right after launch.
    public let pending: [DiagnosisContext]

    public var worst: Severity { areaSeverity.values.max() ?? .ok }
    public var isAllClear: Bool { headline == nil && pending.isEmpty }

    public static let allClear = Verdict(headline: nil, also: [], areaSeverity: [:])

    public init(headline: DiagnosisContext?, also: [DiagnosisContext],
                areaSeverity: [Diagnosis.Area: Severity], pending: [DiagnosisContext] = []) {
        self.headline = headline
        self.also = also
        self.areaSeverity = areaSeverity
        self.pending = pending
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
        isHidden: (String) -> Bool
    ) -> Verdict {
        let visibleProblems = contexts.filter {
            $0.diagnosis.tier == .problem && !isHidden($0.diagnosis.title)
        }
        let gated = visibleProblems
            .filter { $0.durationSeconds >= iconGateSeconds }
            .sorted(by: isMoreImportant)
        let pending = visibleProblems
            .filter { $0.durationSeconds < iconGateSeconds }
            .sorted(by: isMoreImportant)
        var areaSeverity: [Diagnosis.Area: Severity] = [:]
        for c in gated {
            areaSeverity[c.diagnosis.area] = max(areaSeverity[c.diagnosis.area] ?? .ok, c.diagnosis.severity)
        }
        return Verdict(headline: gated.first, also: Array(gated.dropFirst()),
                       areaSeverity: areaSeverity, pending: pending)
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
    public static func shouldNotify(_ c: DiagnosisContext) -> Bool {
        c.diagnosis.tier == .problem
            && c.diagnosis.severity == .critical
            && c.durationSeconds >= notifyGateSeconds
            && c.diagnosis.action != nil
    }
}
