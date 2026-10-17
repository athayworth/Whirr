import Foundation

/// One-line action hint macOS renders between the title and body of a
/// diagnosis notification. Kept as a pure function in WhirrCore (rather
/// than a method on NotificationService, which lives in the executable
/// target and can't be unit-tested) so we can lock down the mapping.
///
/// **Coverage contract**: every rule-emitted title in `RulesEngine`
/// either has a case here or falls into a dynamic pattern. The
/// SubtitleCoverageTests exercise this — adding a new rule without
/// updating this switch will trip a test.
public enum NotificationSubtitles {
    public static func subtitle(for title: String) -> String? {
        // Dynamic-suffix titles first — these embed a process name.
        if title.hasSuffix("has been pegging CPU") {
            return "Force-quit the process if you weren't expecting the work."
        }
        if title.hasSuffix("memory has been growing") {
            return "Looks like a leak — restarting the app will recover the memory."
        }

        switch title {
        // Memory
        case "Memory is saturated", "Memory + swap death spiral":
            return "Close an app to free memory."
        case "Memory is tight":
            return "Watch what you add — headroom is low."
        case "System is actively paging":
            return "Close something — the machine is thrashing swap."
        case "Swap is holding old pages":
            return "No action needed — swap will drop as you close apps."

        // CPU / load / thermal
        case "System is overloaded":
            return "Too many processes competing for CPU."
        case "CPU is critically hot", "CPU is throttling from heat":
            return "Check airflow — performance is being held back."
        case "Cooling matters more than killing right now":
            return "Improving airflow will recover more than force-quitting."

        // Disk
        case "Disk is nearly full":
            return "Clear space to keep the system snappy."
        case "Disk is busy":
            return "Wait for the I/O to finish or close the process moving data."
        case "Disk and memory are fighting for the same SSD":
            return "Close the disk-heavy process or free RAM — either breaks the contention."

        // Backup
        case "Backup is using your system",
             "Foreground apps will feel frozen":
            return "Pause the backup to reclaim disk bandwidth."

        // Rendering / OS
        case "Graphics layer is bottlenecking":
            return "A graphics-heavy app is behind this — close the biggest one."
        case "Spotlight is reindexing":
            return "No action needed — this finishes on its own."

        // Docker
        case "Docker is using significant resources", "Docker is a major load on your Mac":
            return "Stop unused containers to reclaim memory and CPU."

        // Idle
        case "Big processes that look unused":
            return "Close any you don't need — you can restart them anytime."

        default:
            return nil
        }
    }
}
