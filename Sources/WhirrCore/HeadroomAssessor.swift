import Foundation

/// Answers the question the user actually asks: "can I keep going, or do
/// I need to close something before starting the next thing?" Pure
/// function of one snapshot + the current process list — no smoothing, no
/// hysteresis. The trend-aware layer sits above this in the UI.
///
/// The verdict is a coarse three-way (comfortable / tight / pressed)
/// because that's the granularity a decision maps to: nothing to do, one
/// thing to keep in mind, one thing to close now.
public enum HeadroomAssessor {

    /// Threshold in bytes of "available" memory. Below this we say the
    /// system is genuinely pressed. 1.5 GB is enough that macOS can serve
    /// one meaningful new allocation without paging; below that a Chrome
    /// tab open or an Xcode build kick can push the machine into swap.
    static let pressedAvailableFloorBytes: UInt64 = 1_500 * 1_048_576
    /// Below this, "tight" — you're OK now but you're one heavy thing
    /// away. Chosen so the machine has ~1/8 of typical modern RAM (16 GB)
    /// of slack; still comfortable, but no longer "plenty."
    static let tightAvailableFloorBytes: UInt64 = 3_500 * 1_048_576

    public static func assess(
        snapshot: SystemSnapshot,
        processes: [ProcessSample],
        // Page-in threshold from RulesConfig — same knob that controls
        // SwapThrashingRule's "actively paging" decision, so tuning one
        // flows through to both. Prior code hardcoded a separate 1000
        // here which could disagree with the swap rule's 500 default.
        pageInThreshold: Double = SwapThrashingRuleConfig().thrashingPageInsPerSecond
    ) -> HeadroomAssessment {
        let total = snapshot.memoryUsedBytes &+ snapshot.memoryAvailableBytes
        let available = snapshot.memoryAvailableBytes

        // Top hog — the process the user could close for the biggest
        // memory win. Nil out when the top hog is trivial (< 500 MB)
        // because naming it in the UI just clutters when there's nothing
        // to recover.
        let topHog = processes
            .sorted { $0.memoryBytes > $1.memoryBytes }
            .first { $0.memoryBytes >= 500 * 1_048_576 }

        let verdict = classify(snapshot: snapshot, available: available, pageInThreshold: pageInThreshold)
        let headline = headline(for: verdict, availableBytes: available, snapshot: snapshot, pageInThreshold: pageInThreshold)
        let context = context(for: verdict, topHog: topHog, snapshot: snapshot)

        return HeadroomAssessment(
            availableMemoryBytes: available,
            totalMemoryBytes: total,
            verdict: verdict,
            headline: headline,
            context: context,
            topHogName: topHog?.name,
            topHogBytes: topHog?.memoryBytes
        )
    }

    private static func classify(
        snapshot: SystemSnapshot,
        available: UInt64,
        pageInThreshold: Double
    ) -> HeadroomAssessment.Verdict {
        // Kernel pressure trumps everything. If the kernel says pressed,
        // we say pressed regardless of the byte count — the OS is already
        // taking measures, and the user's disk-as-RAM latency is real.
        if snapshot.memoryPressure == .critical { return .pressed }
        // Real page-in activity means the machine is actively reading
        // swapped-out pages back — this is thrashing, and it hurts even
        // if the "available" bucket looks fine at the sample instant.
        if snapshot.pageInsPerSecond >= pageInThreshold { return .pressed }

        if available < pressedAvailableFloorBytes { return .pressed }
        if snapshot.memoryPressure == .warning { return .tight }
        if available < tightAvailableFloorBytes { return .tight }
        return .comfortable
    }

    private static func headline(
        for verdict: HeadroomAssessment.Verdict,
        availableBytes: UInt64,
        snapshot: SystemSnapshot,
        pageInThreshold: Double
    ) -> String {
        let gb = Double(availableBytes) / 1_073_741_824
        let gbFormatted = String(format: "%.1f GB", gb)
        switch verdict {
        case .comfortable:
            return "Safe to keep going. \(gbFormatted) of headroom."
        case .tight:
            return "Working fine — \(gbFormatted) of headroom. Watch what you add."
        case .pressed:
            if snapshot.pageInsPerSecond >= pageInThreshold {
                return "Under pressure — macOS is actively paging."
            }
            return "Under pressure. Close something to recover."
        }
    }

    private static func context(
        for verdict: HeadroomAssessment.Verdict,
        topHog: ProcessSample?,
        snapshot: SystemSnapshot
    ) -> String {
        if let hog = topHog {
            let gb = Double(hog.memoryBytes) / 1_073_741_824
            let hogSize = gb >= 1.0
                ? String(format: "%.1f GB", gb)
                : String(format: "%.0f MB", Double(hog.memoryBytes) / 1_048_576)
            switch verdict {
            case .comfortable:
                return "\(hog.name) is your biggest process at \(hogSize) — plenty of room to keep working."
            case .tight:
                return "\(hog.name) is holding \(hogSize). Closing it would recover roughly that much."
            case .pressed:
                // Kept generic — "close it" applies to any process type
                // (VM, browser, editor). Prior "tabs/files" language read
                // oddly for VMs like Docker's Virtualization host.
                return "\(hog.name) is holding \(hogSize) — closing it is the fastest way to recover memory."
            }
        }
        switch verdict {
        case .comfortable:  return "No big memory hog to point at right now."
        case .tight:        return "No single big hog — pressure comes from many processes."
        case .pressed:      return "No single dominant process — closing several apps may be needed."
        }
    }
}
