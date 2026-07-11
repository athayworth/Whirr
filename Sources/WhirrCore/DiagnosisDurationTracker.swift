import Foundation

/// Turns a stream of tick-scoped `[Diagnosis]` into `[DiagnosisContext]`
/// annotated with duration + trend. Called from the sampling pipeline
/// each tick.
///
/// **Identity** is the diagnosis title (matches `DiagnosisChangeTracker`).
/// A title with the same words is the "same" diagnosis even if severity
/// or detail shifted — that's what the user experiences as "the memory
/// warning that's been on all afternoon."
///
/// **Duration** is measured from the first tick a given title appeared
/// in continuously. Once a title stops appearing for a full clear window
/// (see `clearReset`), the next appearance restarts the clock.
///
/// **Trend** is a coarse three-way from comparing current severity with
/// what we recorded a while ago (`trendLookbackSeconds`). Coarser than a
/// derivative — the goal is "should the user feel calmer or less calm
/// than a minute ago?", not a graph.
public struct DiagnosisDurationTracker {
    /// If a title clears for at least this long, we reset its first-seen
    /// clock — coming back after 10 minutes of quiet is "new," not "still
    /// on for 40 min." Below this we treat brief absences as sampling
    /// noise and preserve the streak.
    public static let defaultClearReset: TimeInterval = 60

    /// How far back to look when comparing severity for trend. Long
    /// enough to average across sampling jitter, short enough to feel
    /// responsive to the user.
    public static let defaultTrendLookback: TimeInterval = 60

    private let clearReset: TimeInterval
    private let trendLookbackSeconds: TimeInterval

    /// Per-title state we need to remember across ticks.
    private struct State {
        var firstSeenAt: Date
        var lastSeenAt: Date
        var lastSeverity: Severity
        /// Highest severity observed since firstSeenAt. Used when
        /// emitting a closed incident so the log records "how bad did
        /// this get" rather than "how bad was it at the very end."
        var peakSeverity: Severity
        var culprits: [String]
        /// Last-observed severity that's at least `trendLookbackSeconds`
        /// stale. Filled the first time we see a sample that's old
        /// enough; used for trend comparison. Nil until we have that
        /// history, in which case trend is `.stable`.
        var referenceSeverity: Severity?
        var referenceCapturedAt: Date?
    }
    private var states: [String: State] = [:]

    public init(
        clearReset: TimeInterval = DiagnosisDurationTracker.defaultClearReset,
        trendLookback: TimeInterval = DiagnosisDurationTracker.defaultTrendLookback
    ) {
        self.clearReset = clearReset
        self.trendLookbackSeconds = trendLookback
    }

    /// Output of one annotation cycle: the per-diagnosis contexts to
    /// render *plus* any incidents that just closed. Closed incidents
    /// are what the pipeline appends to the persistent log for the
    /// Insights charts.
    public struct AnnotationResult {
        public let contexts: [DiagnosisContext]
        public let closedIncidents: [DiagnosisIncident]
    }

    /// Consume this tick's diagnoses; return annotated contexts and any
    /// incidents that just closed (title stopped firing for at least
    /// `clearReset` seconds).
    public mutating func annotate(
        _ diagnoses: [Diagnosis],
        now: Date = Date()
    ) -> AnnotationResult {
        let presentTitles = Set(diagnoses.map(\.title))

        // Detect entries about to be purged — these are titles whose
        // clear-reset window has expired since they were last seen.
        // Emit them as closed incidents so the log records them.
        var closed: [DiagnosisIncident] = []
        for (title, state) in states {
            guard !presentTitles.contains(title) else { continue }
            let age = now.timeIntervalSince(state.lastSeenAt)
            guard age >= clearReset else { continue }
            closed.append(DiagnosisIncident(
                title: title,
                peakSeverity: state.peakSeverity,
                firstSeenAt: state.firstSeenAt,
                lastSeenAt: state.lastSeenAt,
                culprits: state.culprits
            ))
        }

        // Purge state entries whose title hasn't been seen for longer
        // than the clear-reset window. These are the incidents we just
        // emitted plus any that never had a peak severity worth logging.
        states = states.filter { key, state in
            presentTitles.contains(key) || now.timeIntervalSince(state.lastSeenAt) < clearReset
        }

        var contexts: [DiagnosisContext] = []
        contexts.reserveCapacity(diagnoses.count)

        for diagnosis in diagnoses {
            let updated = update(state: states[diagnosis.title], with: diagnosis, now: now)
            states[diagnosis.title] = updated

            let duration = Int(now.timeIntervalSince(updated.firstSeenAt))
            let trend = computeTrend(current: diagnosis.severity, reference: updated.referenceSeverity)
            contexts.append(DiagnosisContext(
                diagnosis: diagnosis,
                firstSeenAt: updated.firstSeenAt,
                durationSeconds: max(0, duration),
                trend: trend
            ))
        }
        return AnnotationResult(contexts: contexts, closedIncidents: closed)
    }

    private func update(state: State?, with diagnosis: Diagnosis, now: Date) -> State {
        guard var existing = state else {
            // First appearance (or first after full clear reset).
            return State(
                firstSeenAt: now,
                lastSeenAt: now,
                lastSeverity: diagnosis.severity,
                peakSeverity: diagnosis.severity,
                culprits: diagnosis.culprits,
                referenceSeverity: nil,
                referenceCapturedAt: nil
            )
        }
        if existing.referenceSeverity == nil,
           now.timeIntervalSince(existing.firstSeenAt) >= trendLookbackSeconds {
            existing.referenceSeverity = existing.lastSeverity
            existing.referenceCapturedAt = existing.lastSeenAt
        } else if let capturedAt = existing.referenceCapturedAt,
                  now.timeIntervalSince(capturedAt) >= trendLookbackSeconds * 2 {
            existing.referenceSeverity = existing.lastSeverity
            existing.referenceCapturedAt = existing.lastSeenAt
        }
        existing.lastSeenAt = now
        existing.lastSeverity = diagnosis.severity
        existing.peakSeverity = max(existing.peakSeverity, diagnosis.severity)
        // Merge in any new culprit names — often the culprits list
        // changes as the incident progresses (memory pressure sees
        // different top hogs over time). Log the union so the incident
        // record reflects everything involved.
        if !diagnosis.culprits.isEmpty {
            let existingSet = Set(existing.culprits)
            for name in diagnosis.culprits where !existingSet.contains(name) {
                existing.culprits.append(name)
            }
        }
        return existing
    }

    private func computeTrend(current: Severity, reference: Severity?) -> DiagnosisContext.Trend {
        guard let ref = reference else { return .stable }
        if current > ref { return .worsening }
        if current < ref { return .improving }
        return .stable
    }
}
