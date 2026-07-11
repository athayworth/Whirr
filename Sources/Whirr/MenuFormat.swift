import Foundation

/// Shared formatters used across the menu bar UI. Lives here so individual
/// section views don't each redefine `formatBytes` / `formatRate` (the prior
/// implementation had four copies of the same byte formatter).
enum MenuFormat {
    /// `1.5 GB` at or above 1 GiB; `512 MB` below. Memory-style binary units.
    static func bytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    /// `1.5 MB/s` below 10 MB/s; `34 MB/s` at or above — the decimal is only
    /// useful at low rates where it shows whether disk is doing anything.
    static func rate(_ bytesPerSec: UInt64) -> String {
        let mb = Double(bytesPerSec) / 1_048_576
        if mb >= 10 { return String(format: "%.0f MB/s", mb) }
        return String(format: "%.1f MB/s", mb)
    }

    /// Per-core CPU percent. Multi-core values (>= 10%) read better without
    /// the decimal noise — `132%` beats `132.4%`. Sub-10% gets a decimal so
    /// background activity isn't all rendered as `0%` / `1%`.
    static func cpu(_ percent: Double) -> String {
        if percent >= 10 { return String(format: "%.0f%%", percent) }
        return String(format: "%.1f%%", percent)
    }

    /// Human duration for "on for X" badges next to diagnoses. Rounds to
    /// the most relevant unit — seconds/minutes/hours — and avoids
    /// awkward mixed forms like "1h 3m" (a diagnosis being "1h 3m" old
    /// vs. "1h 5m" old isn't a distinction worth showing).
    static func duration(seconds: Int) -> String {
        if seconds < 60 { return "\(max(0, seconds))s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600)h"
    }

    /// "in 42 min" / "in 2h" — reverse of `duration(seconds:)`, used for
    /// snooze-expiry hints.
    static func timeUntil(_ until: Date, from now: Date = Date()) -> String {
        let seconds = Int(until.timeIntervalSince(now))
        guard seconds > 0 else { return "expired" }
        return "in \(duration(seconds: seconds))"
    }
}
