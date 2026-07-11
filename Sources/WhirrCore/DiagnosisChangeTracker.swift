import Foundation

/// Edge-triggered tracking of which critical diagnoses are *newly* firing.
/// A diagnosis is considered "the same" as long as its title matches —
/// title is the user-visible headline and the right granularity for
/// "should we alert again?".
///
/// A per-title cooldown prevents notification storms when a condition
/// flaps on and off across a few sampling ticks. Once a title is notified,
/// it won't notify again until either it stays inactive past the cooldown
/// (then becomes critical again), or it stops being critical entirely and
/// the cooldown for that title expires.
public struct DiagnosisChangeTracker {
    public static let defaultCooldown: TimeInterval = 300  // 5 minutes

    private var previousCriticalKeys: Set<String> = []
    private var cooldownUntil: [String: Date] = [:]
    private let cooldown: TimeInterval

    public init(cooldown: TimeInterval = DiagnosisChangeTracker.defaultCooldown) {
        self.cooldown = cooldown
    }

    /// Cooldown value + a copy of the state (previouslyCritical +
    /// cooldownUntil) needed to migrate across a rebuild — used by
    /// NotificationService when the user changes the cooldown
    /// preference. Prior code discarded the whole tracker and reset
    /// per-title flap suppression; migrating state keeps the
    /// "already-notified" pact intact.
    public struct State: Sendable, Equatable {
        public let previousCriticalKeys: Set<String>
        public let cooldownUntil: [String: Date]
        public init(previousCriticalKeys: Set<String>, cooldownUntil: [String: Date]) {
            self.previousCriticalKeys = previousCriticalKeys
            self.cooldownUntil = cooldownUntil
        }
    }

    public var snapshot: State {
        State(previousCriticalKeys: previousCriticalKeys, cooldownUntil: cooldownUntil)
    }

    /// Rebuild with a new cooldown while carrying over the flap-
    /// suppression state. `now` clips any migrated cooldowns to at most
    /// `now + newCooldown` so a rebuild that shortens the cooldown
    /// takes effect on the migrated entries too.
    public init(cooldown: TimeInterval, migrating from: State, now: Date = Date()) {
        self.cooldown = cooldown
        self.previousCriticalKeys = from.previousCriticalKeys
        let ceiling = now.addingTimeInterval(cooldown)
        self.cooldownUntil = from.cooldownUntil.mapValues { min($0, ceiling) }
    }

    /// Returns the diagnoses that became newly critical since the last call
    /// and that aren't in cooldown. Updates internal state to reflect the
    /// current critical set.
    public mutating func newlyCritical(in diagnoses: [Diagnosis], now: Date = Date()) -> [Diagnosis] {
        let currentCritical = diagnoses.filter { $0.severity == .critical }
        let currentKeys = Set(currentCritical.map(\.title))

        let candidateKeys = currentKeys.subtracting(previousCriticalKeys)

        var newlyFiring: [Diagnosis] = []
        for diag in currentCritical {
            guard candidateKeys.contains(diag.title) else { continue }
            if let until = cooldownUntil[diag.title], until > now { continue }
            newlyFiring.append(diag)
            cooldownUntil[diag.title] = now.addingTimeInterval(cooldown)
        }

        previousCriticalKeys = currentKeys
        // Drop cooldowns that have fully expired AND whose conditions aren't
        // currently active. Keep entries for currently-active conditions so
        // a brief flap doesn't re-notify.
        cooldownUntil = cooldownUntil.filter { entry in
            entry.value > now || currentKeys.contains(entry.key)
        }

        return newlyFiring
    }

    /// Titles that were critical the last time we saw them but aren't
    /// in the current set — the "all clear" signal. Callers use this
    /// to post recovery notifications so the loop closes ("your
    /// memory pressure has resolved") rather than only alerting on
    /// escalation.
    ///
    /// Called separately from `newlyCritical` so consumers can opt
    /// into recovery pings without affecting the fire-on-escalate
    /// behavior. Order of calls doesn't matter — this is derived from
    /// `previousCriticalKeys` which `newlyCritical` also reads, but
    /// this method doesn't mutate state.
    public func newlyCleared(in diagnoses: [Diagnosis]) -> [String] {
        let currentKeys = Set(diagnoses.filter { $0.severity == .critical }.map(\.title))
        return previousCriticalKeys.subtracting(currentKeys).sorted()
    }
}
