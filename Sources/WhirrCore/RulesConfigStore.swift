import Foundation

/// Loads and writes `rules.json`. Path injectable so tests can drive
/// fixtures without touching the user's real Application Support dir.
///
/// Behavior on disk errors is deliberately forgiving — a missing file,
/// malformed JSON, or unknown formatVersion all fall back to embedded
/// defaults rather than crash. The user can break their config by
/// editing it badly; that shouldn't break the menu bar.
public struct RulesConfigStore: Sendable {
    public static var defaultPath: String {
        let dir = NSHomeDirectory() + "/Library/Application Support/Whirr"
        return dir + "/rules.json"
    }

    public let path: String

    public init(path: String? = nil) {
        self.path = path ?? RulesConfigStore.defaultPath
    }

    public enum LoadResult: Equatable {
        case absent
        case loaded
        case malformed(String)
        case versionMismatch(actual: Int)
    }

    /// Returns `(config, result)`. `config` is always usable — either the
    /// decoded user config or the embedded defaults. `result` lets the
    /// caller surface a hint in the UI ("your file is malformed: …")
    /// without parsing the loader's behavior from the config alone.
    public func load() -> (config: RulesConfig, result: LoadResult) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return (.default, .absent)
        }
        guard let data = try? Data(contentsOf: url) else {
            return (.default, .malformed("could not read file"))
        }
        do {
            let decoded = try JSONDecoder().decode(RulesConfig.self, from: Self.droppingRetiredDefaults(data))
            guard decoded.formatVersion == RulesConfig.currentFormatVersion else {
                return (.default, .versionMismatch(actual: decoded.formatVersion))
            }
            return (decoded, .loaded)
        } catch {
            return (.default, .malformed(error.localizedDescription))
        }
    }

    /// Sections whose values exactly match a default Whirr has since
    /// corrected. "Write defaults" copies every default into the file, so
    /// without this a months-old snapshot would silently pin thresholds
    /// that were changed because they produced false alarms. Values a
    /// person actually edited never match and are kept.
    static let retiredDefaults: [String: [[String: Double]]] = [
        // Disk busy: critical was 200 then 800 MB/s; modern SSDs pass that
        // during an ordinary file copy.
        "highDiskIO": [["warningMBs": 50, "criticalMBs": 200], ["warningMBs": 200, "criticalMBs": 800]],
    ]

    static func droppingRetiredDefaults(_ data: Data) -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        var changed = false
        for (section, olds) in retiredDefaults {
            guard let values = root[section] as? [String: Any] else { continue }
            let numbers = values.compactMapValues { ($0 as? NSNumber)?.doubleValue }
            if olds.contains(where: { old in old.allSatisfy { numbers[$0.key] == $0.value } }) {
                root[section] = nil
                changed = true
            }
        }
        guard changed, let rewritten = try? JSONSerialization.data(withJSONObject: root) else { return data }
        return rewritten
    }

    /// Writes the embedded defaults pretty-printed to disk so the user
    /// has a complete starting point to edit. Creates the parent
    /// directory if needed. Atomic so a reader (e.g., the user's editor
    /// auto-reloading) never sees a half-written file.
    public func writeDefaults() throws {
        try write(.default)
    }

    public func write(_ config: RulesConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}
