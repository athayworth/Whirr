import Foundation

/// A human-readable description of a process. `friendlyName` is the
/// short thing you'd write on a name-tag ("Google Chrome" rather than
/// "Google Chrome Helper (Renderer)"). `explainer` is one line the UI
/// can show alongside so the user knows what the process is *for*
/// without needing to recognize the raw name.
public struct ProcessDescription: Sendable, Hashable {
    public let friendlyName: String
    public let explainer: String
    public let category: Category

    public enum Category: String, Sendable, Codable, Hashable {
        case browser
        case editor
        case communication
        case media
        case productivity
        case cloudSync
        case backup
        case dev
        case container
        case system
        case background
        case app
        case unknown
    }

    public init(friendlyName: String, explainer: String, category: Category) {
        self.friendlyName = friendlyName
        self.explainer = explainer
        self.category = category
    }
}

/// Turns a `ProcessSample` into a `ProcessDescription`. Three-tier strategy:
///
/// 1. **Known name table** — a curated dictionary of the most common
///    macOS processes (browsers, editors, dev tools, system services).
///    This handles the ~150 processes most users will actually see.
///
/// 2. **Info.plist lookup** — for anything in an .app bundle, walk up
///    the executable path to find `.app`, read its `Info.plist`, and
///    pull `CFBundleDisplayName` / `CFBundleName`. This handles every
///    Cocoa app on the system without us having to enumerate them.
///
/// 3. **Raw name fallback** — if we have neither, just show the raw
///    process name with a generic explainer.
///
/// Cached by executable path (or bare name when no path) so we pay the
/// Info.plist read at most once per unique process identity.
public final class ProcessDescriptor: @unchecked Sendable {
    public static let shared = ProcessDescriptor()

    private let lock = NSLock()
    private var cache: [String: ProcessDescription] = [:]

    public init() {}

    /// Describe a process. Never fails — always returns *something*
    /// renderable, even for kernel tasks or other-user processes we
    /// can't introspect.
    public func describe(_ proc: ProcessSample) -> ProcessDescription {
        let key = cacheKey(for: proc)
        if let hit = lock.withLock({ cache[key] }) { return hit }
        let result = compute(proc)
        lock.withLock { cache[key] = result }
        return result
    }

    /// Convenience: just the friendly name. Used where callers want to
    /// substitute a nicer name for the raw process name without the
    /// full description.
    public func friendlyName(for proc: ProcessSample) -> String {
        describe(proc).friendlyName
    }

    private func cacheKey(for proc: ProcessSample) -> String {
        // Executable path is the tightest identity — same binary always
        // resolves the same way. Fall back to name for kernel tasks that
        // don't expose a path.
        proc.executablePath ?? "name:\(proc.name)"
    }

    // MARK: - Compute

    private func compute(_ proc: ProcessSample) -> ProcessDescription {
        // 1. Known-name override wins first. This catches the case where
        // the process name matches a helper we recognize even before we
        // try to walk to the parent bundle.
        if let known = Self.knownByName[proc.name] {
            return known
        }
        // Some CLI-launched processes end up with names like "node" and
        // the specific script in commandLine. For those the name lookup
        // is the right thing; we don't try to be cleverer.

        // 2. Bundle-based resolution for anything in an .app bundle.
        if let path = proc.executablePath, let (bundleName, bundlePath) = topLevelAppBundle(for: path) {
            let display = readBundleDisplayName(bundlePath: bundlePath) ?? bundleName
            // If the bundle display name lands on a known entry (e.g.
            // "Google Chrome" whose helpers all bubble up to it), reuse
            // its category + explainer rather than the generic app copy.
            if let known = Self.knownByName[display] {
                return known
            }
            return ProcessDescription(
                friendlyName: display,
                explainer: "A macOS app you installed. Quitting it via ⌘Q is the right move if you want to free its memory.",
                category: .app
            )
        }

        // 3. Final fallback — raw name with a generic hint tuned to what
        // ProcessClassifier said. Keeps the copy honest ("we don't know
        // what this is") without being alarming.
        return Self.genericDescription(for: proc)
    }

    // MARK: - Bundle path walk

    /// Given an arbitrary executable path, return the *top-level* app
    /// bundle it belongs to and the bundle's basename.
    ///
    /// Example inputs → outputs:
    ///   `/Applications/Slack.app/Contents/MacOS/Slack`
    ///     → ("Slack", "/Applications/Slack.app")
    ///   `/Applications/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper.app/Contents/MacOS/…`
    ///     → ("Google Chrome", "/Applications/Google Chrome.app")   ← top-level, not the helper
    private func topLevelAppBundle(for path: String) -> (name: String, path: String)? {
        // Take the first ".app/" occurrence — that's the outermost .app
        // in the path, which is what the user calls "the app". Nested
        // helper .app bundles are inside it and shouldn't win.
        guard let range = path.range(of: ".app/") else { return nil }
        let bundlePath = String(path[..<range.upperBound].dropLast())  // strip trailing '/'
        // The bundle basename minus ".app" is our first-guess friendly
        // name. Overridden by CFBundleDisplayName if present.
        let filename = (bundlePath as NSString).lastPathComponent  // "Slack.app"
        let name = filename.hasSuffix(".app")
            ? String(filename.dropLast(4))
            : filename
        return (name, bundlePath)
    }

    private func readBundleDisplayName(bundlePath: String) -> String? {
        let plistPath = bundlePath + "/Contents/Info.plist"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any]
        else { return nil }
        // Prefer CFBundleDisplayName (user-facing marketing name), fall
        // back to CFBundleName (may be shorter but still nicer than the
        // raw executable name).
        if let display = dict["CFBundleDisplayName"] as? String, !display.isEmpty {
            return display
        }
        if let name = dict["CFBundleName"] as? String, !name.isEmpty {
            return name
        }
        return nil
    }

    // MARK: - Generic fallback description

    private static func genericDescription(for proc: ProcessSample) -> ProcessDescription {
        let classification = ProcessClassifier.classify(proc)
        switch classification {
        case .systemCritical:
            return ProcessDescription(
                friendlyName: proc.name,
                explainer: "Part of macOS itself. Leave this alone — killing it can log you out or crash the machine.",
                category: .system
            )
        case .systemService:
            return ProcessDescription(
                friendlyName: proc.name,
                explainer: "A macOS background service. launchd will typically restart it within seconds if you kill it.",
                category: .system
            )
        case .helper:
            return ProcessDescription(
                friendlyName: proc.name,
                explainer: "A helper for a parent app. Quit the parent app rather than killing this directly.",
                category: .background
            )
        case .devTool:
            return ProcessDescription(
                friendlyName: proc.name,
                explainer: "A developer tool — usually something you launched from a terminal or via a script. Safe to kill.",
                category: .dev
            )
        case .userApp:
            return ProcessDescription(
                friendlyName: proc.name,
                explainer: "An app you installed. ⌘Q is the right way to close it.",
                category: .app
            )
        case .unknown:
            return ProcessDescription(
                friendlyName: proc.name,
                explainer: "We couldn't determine what this is. Look it up in Activity Monitor before deciding.",
                category: .unknown
            )
        }
    }

    // MARK: - Known names table
    //
    // A hand-curated list of the ~150 most common macOS processes.
    // Coverage strategy: browsers → messaging → editors → design → media
    // → productivity → dev/backup/system. Every entry has a plain-language
    // explainer that would land with a non-technical reader.

    static let knownByName: [String: ProcessDescription] = {
        var m: [String: ProcessDescription] = [:]

        func add(_ names: [String], _ friendly: String, _ explainer: String, _ category: ProcessDescription.Category) {
            let desc = ProcessDescription(friendlyName: friendly, explainer: explainer, category: category)
            for n in names { m[n] = desc }
        }

        // Browsers
        add(["Google Chrome", "Google Chrome Helper", "Google Chrome Helper (Renderer)",
             "Google Chrome Helper (GPU)", "Google Chrome Helper (Plugin)"],
            "Google Chrome",
            "The Chrome web browser. Tabs and extensions each cost memory — closing tabs is the fastest way to free RAM.",
            .browser)
        add(["Safari", "Safari Web Content", "SafariBookmarksSyncAgent", "com.apple.WebKit.WebContent",
             "com.apple.WebKit.GPU", "com.apple.WebKit.Networking"],
            "Safari",
            "Apple's web browser. Tabs run as separate processes; closing tabs frees memory back to the system.",
            .browser)
        add(["Firefox", "firefox", "plugin-container"],
            "Firefox",
            "The Firefox web browser. Closing tabs frees memory.",
            .browser)
        add(["Arc", "Arc Helper", "Arc Helper (Renderer)", "Arc Helper (GPU)"],
            "Arc",
            "The Arc browser (Chromium-based). Each tab / space costs memory; closing tabs frees it.",
            .browser)
        add(["Microsoft Edge", "Microsoft Edge Helper", "Microsoft Edge Helper (Renderer)"],
            "Microsoft Edge",
            "Microsoft's browser (Chromium-based). Tabs are the biggest memory driver.",
            .browser)
        add(["Brave Browser", "Brave Browser Helper"],
            "Brave",
            "The Brave browser (Chromium-based). Closing tabs is the way to free memory.",
            .browser)
        add(["Dia", "Dia Helper"],
            "Dia",
            "The Dia browser. Close tabs to reclaim memory.",
            .browser)

        // Communication
        add(["Slack", "Slack Helper", "Slack Helper (Renderer)", "Slack Helper (GPU)"],
            "Slack",
            "Slack (Electron-based) — chats, workspaces, huddles. Idle Slack usually holds ~500 MB; you can quit it and relaunch when needed.",
            .communication)
        add(["zoom.us", "Zoom", "CptHost", "AirHost"],
            "Zoom",
            "Zoom's meeting client. Even idle it can hold significant memory; quit when you're not in a meeting.",
            .communication)
        add(["Discord", "Discord Helper"],
            "Discord",
            "Discord (Electron-based). Similar footprint to Slack.",
            .communication)
        add(["Microsoft Teams", "Microsoft Teams Helper", "MSTeams", "Teams"],
            "Microsoft Teams",
            "Microsoft Teams client. Notoriously heavy — quitting frees memory.",
            .communication)
        add(["Messages", "MessagesViewer", "imagent"],
            "Messages",
            "Apple's Messages app — iMessage and SMS. Lightweight; usually safe to keep running.",
            .communication)
        add(["FaceTime", "FaceTime Camera"],
            "FaceTime",
            "Apple's video-call app. Safe to quit when not in a call.",
            .communication)
        add(["Mail"],
            "Mail",
            "Apple Mail. Large mailboxes can drive memory; quit if you don't need it right now.",
            .communication)
        add(["Signal"],
            "Signal",
            "The Signal messenger. Safe to quit and relaunch.",
            .communication)
        add(["WhatsApp", "WhatsApp Helper"],
            "WhatsApp",
            "WhatsApp desktop. Safe to quit and relaunch.",
            .communication)
        add(["Telegram"],
            "Telegram",
            "Telegram desktop. Safe to quit and relaunch.",
            .communication)

        // Editors / IDEs
        add(["Xcode", "com.apple.dt.Xcode"],
            "Xcode",
            "Apple's IDE. Builds + indexers can hold gigabytes; closing unused projects helps most.",
            .editor)
        add(["Code", "Code Helper", "Code Helper (Renderer)", "Code Helper (Plugin)",
             "Visual Studio Code"],
            "Visual Studio Code",
            "VS Code (Electron-based). Extensions and language servers are the memory driver; quitting the window frees them.",
            .editor)
        add(["Cursor", "Cursor Helper", "Cursor Helper (Renderer)"],
            "Cursor",
            "Cursor (VS Code fork with AI). Same memory pattern as VS Code — extensions + language servers.",
            .editor)
        add(["Windsurf", "Windsurf Helper"],
            "Windsurf",
            "The Windsurf AI code editor. Language servers + AI backend hold memory.",
            .editor)
        add(["Zed"],
            "Zed",
            "The Zed code editor. Native (Rust-based), typically lighter than Electron editors.",
            .editor)
        add(["Sublime Text"],
            "Sublime Text",
            "The Sublime Text editor. Lightweight — usually not what's holding memory.",
            .editor)
        add(["idea", "IntelliJ IDEA", "PyCharm", "WebStorm", "GoLand", "RubyMine", "PhpStorm",
             "CLion", "DataGrip", "Rider"],
            "JetBrains IDE",
            "A JetBrains IDE. Indexing + language servers can hold gigabytes; closing unused projects helps.",
            .editor)
        add(["Nova"],
            "Nova",
            "The Nova editor (Panic). Native, generally lightweight.",
            .editor)
        add(["Emacs"],
            "Emacs",
            "The Emacs editor. Safe to quit when you're not editing.",
            .editor)
        add(["Vim", "vim", "MacVim", "nvim"],
            "Vim / Neovim",
            "The Vim / Neovim editor. Safe to quit when you're not editing.",
            .editor)

        // AI coding assistants
        add(["claude", "Claude", "claude-code"],
            "Claude Code",
            "Anthropic's Claude Code CLI. Safe to close — you can restart it when you're back to coding.",
            .dev)
        add(["codex"],
            "Codex",
            "OpenAI's Codex CLI. Safe to close.",
            .dev)

        // Design
        add(["Figma", "Figma Helper", "Figma Helper (Renderer)"],
            "Figma",
            "Figma (Electron-based). Large designs eat memory; closing the tab frees it.",
            .productivity)
        add(["Sketch"],
            "Sketch",
            "The Sketch design app.",
            .productivity)
        add(["Adobe Photoshop", "Photoshop"],
            "Adobe Photoshop",
            "Photoshop. Open documents hold memory proportional to their canvas size.",
            .productivity)
        add(["Adobe Illustrator", "Illustrator"],
            "Adobe Illustrator",
            "Illustrator.",
            .productivity)
        add(["Adobe After Effects", "After Effects"],
            "Adobe After Effects",
            "After Effects. Very memory-hungry; quit when done.",
            .productivity)
        add(["Adobe Premiere Pro", "Premiere Pro"],
            "Adobe Premiere Pro",
            "Premiere Pro. Very memory-hungry; quit when done.",
            .productivity)
        add(["Creative Cloud"],
            "Adobe Creative Cloud",
            "Adobe's background updater/launcher. Safe to quit if you're not launching Adobe apps.",
            .background)

        // Media
        add(["Spotify", "Spotify Helper"],
            "Spotify",
            "The Spotify music app. Modest footprint but not tiny.",
            .media)
        add(["Music"],
            "Apple Music",
            "The Music app (Apple Music). Safe to quit when you're not listening.",
            .media)
        add(["Podcasts"],
            "Podcasts",
            "Apple Podcasts. Safe to quit when you're not listening.",
            .media)
        add(["VLC"],
            "VLC",
            "The VLC media player. Safe to quit when not watching.",
            .media)
        add(["IINA"],
            "IINA",
            "The IINA media player. Safe to quit when not watching.",
            .media)
        add(["QuickTime Player"],
            "QuickTime Player",
            "Apple's QuickTime Player. Safe to quit when not watching / recording.",
            .media)
        add(["Photos", "photoanalysisd", "mediaanalysisd"],
            "Photos",
            "Apple Photos + its background analyzers. The analyzers run automatically after imports; usually best to let them finish.",
            .media)

        // Productivity / Notes
        add(["Notion", "Notion Helper"],
            "Notion",
            "Notion (Electron). Larger workspaces drive memory usage; quitting works fine.",
            .productivity)
        add(["Obsidian", "Obsidian Helper"],
            "Obsidian",
            "Obsidian (Electron).",
            .productivity)
        add(["Bear"],
            "Bear",
            "The Bear notes app. Lightweight.",
            .productivity)
        add(["Notes"],
            "Apple Notes",
            "Apple Notes. Lightweight.",
            .productivity)
        add(["Numbers", "Pages", "Keynote"],
            "iWork app",
            "One of Apple's iWork apps (Numbers/Pages/Keynote).",
            .productivity)
        add(["1Password", "1Password 7", "1Password Extension Helper"],
            "1Password",
            "1Password. Safe to keep running; quitting will prompt you to log in again.",
            .productivity)
        add(["Alfred", "Alfred 5"],
            "Alfred",
            "The Alfred launcher. Lightweight; keeping it running is fine.",
            .background)
        add(["Raycast"],
            "Raycast",
            "The Raycast launcher. Lightweight; keeping it running is fine.",
            .background)
        add(["Rectangle", "Rectangle Pro"],
            "Rectangle",
            "The Rectangle window manager. Lightweight.",
            .background)

        // Cloud / sync
        add(["Dropbox", "Dropbox Helper"],
            "Dropbox",
            "Dropbox sync client. Idle it's cheap; heavy uploads can drive CPU + disk.",
            .cloudSync)
        add(["Google Drive", "Backup and Sync", "Drive File Stream"],
            "Google Drive",
            "Google Drive sync. Heavy uploads/downloads can drive CPU + disk.",
            .cloudSync)
        add(["OneDrive"],
            "OneDrive",
            "Microsoft OneDrive sync client.",
            .cloudSync)
        add(["bird"],
            "iCloud Drive",
            "The iCloud Drive sync daemon (bird). Heavy syncs can drive CPU + disk; usually best to let it finish.",
            .cloudSync)
        add(["cloudd"],
            "iCloud services",
            "iCloud background services. Usually harmless; killing it just prompts a relaunch.",
            .cloudSync)

        // Backup
        add(["backupd", "backupd-helper"],
            "Time Machine",
            "Apple's Time Machine backup service. Pausing (from the menu bar icon) is safer than killing it.",
            .backup)
        add(["bzserv", "bztransmit", "bzfilelist", "bzbmenu"],
            "Backblaze",
            "The Backblaze online backup service. Pause it from the Backblaze menu bar icon instead of killing.",
            .backup)

        // Docker + containers
        add(["com.docker.backend", "com.docker.vpnkit", "com.docker.diagnose",
             "com.docker.dev-envs", "Docker", "Docker Desktop"],
            "Docker Desktop",
            "Docker Desktop and its VM. Idle Docker with no running containers still holds ~1 GB; running containers add more.",
            .container)
        // macOS's Virtualization.framework host process. Docker Desktop
        // is by far the most common thing that spawns this (its Linux
        // VM runs on it), but Parallels, UTM, and other VM tools can
        // too — so the copy hedges rather than claiming Docker. The
        // libproc name gets truncated to 16 chars, hence the "Virtua"
        // variants.
        add(["com.apple.Virtualization", "com.apple.Virtualization.Virtua",
             "com.apple.Virtualization.VirtualMachine",
             "Virtualization", "VirtualizationVM"],
            "Virtualization VM (probably Docker)",
            "macOS's Virtualization framework running a guest VM. Almost always Docker Desktop's Linux VM; can also be Parallels, UTM, or another VM tool. Quit Docker Desktop (or your VM tool) to free the memory.",
            .container)

        // Dev servers / runtimes
        add(["node", "nodejs"],
            "Node.js",
            "A Node.js process — usually a dev server, script, or bundler. Safe to kill; restart from your terminal if you want it back.",
            .dev)
        add(["python", "python3", "Python"],
            "Python",
            "A Python process — usually a script or dev server. Safe to kill; restart the script if you want it back.",
            .dev)
        add(["ruby", "Ruby"],
            "Ruby",
            "A Ruby process — often a Rails server or script. Safe to kill.",
            .dev)
        add(["java", "Java"],
            "Java",
            "A Java process — could be a build tool, dev server, or IDE. Kill only if you know which.",
            .dev)
        add(["bun"],
            "Bun",
            "A Bun runtime — usually a dev server or script. Safe to kill.",
            .dev)
        add(["deno"],
            "Deno",
            "A Deno runtime — usually a dev server or script. Safe to kill.",
            .dev)
        add(["go"],
            "Go",
            "A Go process — usually a compile or dev server. Safe to kill.",
            .dev)
        add(["cargo", "rustc"],
            "Rust build",
            "A Rust build (cargo/rustc). Killing it aborts a compile — not harmful, just wastes the work.",
            .dev)
        add(["postgres", "postgresql"],
            "PostgreSQL",
            "The PostgreSQL database server. If launched by Homebrew or Postgres.app, stopping is preferable to killing.",
            .dev)
        add(["redis-server", "redis"],
            "Redis",
            "The Redis in-memory data store. Data is lost on kill unless persistence is configured.",
            .dev)
        add(["mysqld", "mysql"],
            "MySQL",
            "The MySQL database server. Stop it via brew services / mysql.server rather than killing.",
            .dev)
        add(["nginx"],
            "nginx",
            "The nginx web server / reverse proxy. If launched by Homebrew, `brew services stop nginx` is safer.",
            .dev)
        add(["ollama"],
            "Ollama",
            "The Ollama local LLM runtime. Big memory footprint per loaded model.",
            .dev)

        // System / OS
        add(["kernel_task"],
            "kernel_task",
            "The macOS kernel itself. You can't kill this; high CPU here usually means the kernel is throttling to cool the CPU.",
            .system)
        add(["launchd"],
            "launchd",
            "macOS's process supervisor. Killing this reboots the machine — leave it alone.",
            .system)
        add(["WindowServer"],
            "WindowServer",
            "The macOS graphics compositor. High CPU here usually points at a heavy graphics app (Chrome with many tabs, Electron apps, screen recording).",
            .system)
        add(["mds", "mds_stores"],
            "Spotlight indexer",
            "Spotlight's indexer. Runs when files change; expect 10–30 minutes of high usage after a new volume mount or big file move. Wait it out rather than killing.",
            .system)
        add(["Dock"],
            "Dock",
            "The macOS Dock. Killing it just relaunches — it's a systemUIServer sibling, safe to relaunch if it's misbehaving.",
            .system)
        add(["Finder"],
            "Finder",
            "The Finder. Killing it relaunches automatically.",
            .system)
        add(["SystemUIServer", "ControlCenter", "NotificationCenter"],
            "System UI",
            "Menu bar, Control Center, or Notification Center. Killing it relaunches automatically.",
            .system)
        add(["loginwindow"],
            "loginwindow",
            "The macOS login/session process. Killing it logs you out — leave it alone.",
            .system)
        add(["talagentd", "talagent"],
            "Terminal launch agent",
            "A macOS session helper. Usually not the cause of slowdowns; safe to leave alone.",
            .system)
        add(["photoanalysisd"],
            "Photo analyzer",
            "Photos' background analyzer. Runs after imports to identify people/scenes. Wait it out rather than killing.",
            .system)
        add(["cloudphotod"],
            "iCloud Photos",
            "iCloud Photos background sync. Wait it out rather than killing.",
            .system)
        add(["mdworker", "mdworker_shared"],
            "Spotlight worker",
            "A short-lived Spotlight indexer helper. It'll exit on its own when the indexing chunk is done.",
            .system)
        add(["syslogd"],
            "System logger",
            "macOS's system-log daemon. Leave it alone.",
            .system)
        add(["hidd"],
            "Input daemon",
            "macOS's keyboard/mouse/trackpad daemon. Do not kill.",
            .system)
        add(["coreaudiod"],
            "Audio daemon",
            "macOS's core audio daemon. Do not kill unless audio is stuck.",
            .system)
        add(["bluetoothd"],
            "Bluetooth daemon",
            "macOS's Bluetooth daemon. Killing it will disconnect all Bluetooth devices.",
            .system)

        return m
    }()
}
