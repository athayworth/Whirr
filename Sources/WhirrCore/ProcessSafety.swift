import Foundation

/// "Is this process safe to stop?" classification surfaced next to each
/// process in the menu bar. Deliberately coarse — six buckets that map to
/// short, action-oriented advice. Better to be slightly wrong about
/// edge-cases than to overload the UI with subtle distinctions.
public enum ProcessSafety: String, Sendable, Codable, Hashable {
    /// Required by macOS. Killing this will at minimum log you out, at
    /// worst crash the machine. Examples: kernel_task, launchd,
    /// WindowServer, loginwindow.
    case systemCritical

    /// macOS-shipped service that's not load-bearing for the desktop.
    /// Safe to kill in principle, but launchd will usually relaunch it
    /// within seconds, so killing rarely accomplishes anything.
    case systemService

    /// A user-installed app (lives in /Applications or
    /// /System/Applications). Quitting it via Cmd-Q is the right move.
    case userApp

    /// User-installed background helper for a parent app (e.g., Arc
    /// renderer, Slack helper). Killing this directly often crashes the
    /// parent or just gets respawned. Quit the parent instead.
    case helper

    /// A dev tool the user almost certainly launched themselves: node,
    /// python, java, etc. Safe to kill via `kill <pid>`.
    case devTool

    /// We don't have enough information to classify (typically because
    /// the executable path isn't readable). Be cautious.
    case unknown

    public var label: String {
        switch self {
        case .systemCritical: return "system"
        case .systemService:  return "service"
        case .userApp:        return "app"
        case .helper:         return "helper"
        case .devTool:        return "dev"
        case .unknown:        return "?"
        }
    }

    /// One-line guidance the UI can show in a tooltip / detail view.
    public var advice: String {
        switch self {
        case .systemCritical: return "Required by macOS — leave it alone."
        case .systemService:  return "System service — launchd will respawn it if you kill it."
        case .userApp:        return "Safe to quit via Cmd-Q."
        case .helper:         return "Quit the parent app, not this helper directly."
        case .devTool:        return "Safe to kill — restart your script if you still want it running."
        case .unknown:        return "Source unknown — open Activity Monitor for more detail before killing."
        }
    }
}

/// Pure classifier — given a ProcessSample, return its safety bucket.
/// Order of checks matters: more specific patterns first.
public enum ProcessClassifier {
    /// Names that ALWAYS classify as systemCritical regardless of path.
    /// Killing any of these is a bad day. Owned by root, but we don't
    /// gate on uid — even if some run as the user (rare), they still
    /// shouldn't be killed.
    private static let criticalNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow",
        "logind", "Dock", "Finder", "SystemUIServer", "ControlCenter",
        "NotificationCenter", "talagent", "talagentd"
    ]

    /// Substrings that mark a process as a helper of a parent app.
    /// Checked before path-based classification because Arc's renderer
    /// helpers live under /Applications/Arc.app/... and would otherwise
    /// match `userApp`.
    private static let helperPatterns = [
        "Helper", "Renderer", "GPU Process", "Web Content",
        "WebKit", " (Plugin)", "Service"
    ]

    /// Dev-tool binary names. We match on the bare process name (libproc's
    /// 16-char limit doesn't hurt us here — these are all short).
    private static let devToolNames: Set<String> = [
        "node", "python", "python3", "ruby", "java", "bun", "deno",
        "go", "rustc", "cargo", "gradle", "mvn", "sbt", "tsc",
        "esbuild", "webpack", "vite", "next-server", "ng",
        "pip", "uv", "poetry", "pnpm", "yarn", "npm"
    ]

    public static func classify(_ proc: ProcessSample) -> ProcessSafety {
        if criticalNames.contains(proc.name) {
            return .systemCritical
        }
        for pattern in helperPatterns where proc.name.contains(pattern) {
            return .helper
        }
        if let path = proc.executablePath {
            if path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/")
                || path.hasPrefix("/usr/sbin/") || path.hasPrefix("/sbin/")
                || path.hasPrefix("/usr/bin/") {
                return .systemService
            }
            if path.hasPrefix("/Applications/") {
                return .userApp
            }
        }
        if devToolNames.contains(proc.name) {
            return .devTool
        }
        return .unknown
    }
}
