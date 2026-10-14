import Foundation
import AppKit

/// Tracks which apps the user has recently focused so the rules engine
/// can tell "CPU-idle but the user has been looking at it" apart from
/// "CPU-idle and the user hasn't touched it in half an hour."
///
/// **Data source**: `NSWorkspace.frontmostApplication.bundleIdentifier`,
/// sampled from the same tick as everything else in the pipeline. No
/// NSWorkspace notifications, no observers to clean up — just a per-
/// tick pull. Accessibility permissions are NOT required; frontmost-
/// app identity is public information.
///
/// **Model**: `bundleId → last-focused Date`. Records overwrite on each
/// re-focus, so the memory footprint stays proportional to the number
/// of distinct apps the user has focused within the lookback window
/// (typically < 20). Entries older than lookback are purged on read.
///
/// **Threading**: `@MainActor` because `NSWorkspace.shared` requires
/// it. Callers on other actors (e.g., the SamplingPipeline task) hop
/// through MainActor.run to sample.
@MainActor
final class FrontmostAppTracker {
    /// How far back "recently focused" reaches. 30 min is a compromise:
    /// short enough that an app you closed at breakfast doesn't stay
    /// exempt at lunch, long enough that a browser you check every few
    /// minutes never gets flagged as unused. Kept as an instance
    /// property so tests can inject a shorter window.
    let lookback: TimeInterval

    /// Bundle ID → last time we observed it as frontmost.
    private var lastFocusedAt: [String: Date] = [:]

    init(lookback: TimeInterval = 30 * 60) {
        self.lookback = lookback
    }

    /// Snapshot the current frontmost app and return the recently-
    /// active bundle IDs. Called from the pipeline tick — we sample
    /// and query in one call so state is fresh each tick without a
    /// separate observer path.
    func recordAndSnapshot(at now: Date = Date()) -> Set<String> {
        if let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           !bundleId.isEmpty {
            lastFocusedAt[bundleId] = now
        }
        return snapshotBundleIds(at: now)
    }

    /// Read-only variant for tests + UI that don't want to touch the
    /// tracker's state. Filters out expired entries on the fly but
    /// does not update the cache.
    func snapshotBundleIds(at now: Date = Date()) -> Set<String> {
        let cutoff = now.addingTimeInterval(-lookback)
        // Purge stale entries — bounded memory even after weeks of
        // uptime. Rare bundle IDs won't stick around beyond lookback.
        lastFocusedAt = lastFocusedAt.filter { $0.value >= cutoff }
        return Set(lastFocusedAt.keys)
    }
}
