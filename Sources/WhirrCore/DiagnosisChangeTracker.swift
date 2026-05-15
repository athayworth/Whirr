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
}
