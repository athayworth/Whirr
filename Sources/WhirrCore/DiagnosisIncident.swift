import Foundation

/// One closed "incident" of a diagnosis — from the first tick it was
/// observed to the last, plus how bad it got. Written to disk when the
/// diagnosis clears (i.e., stays absent for the duration tracker's
/// clear-reset window). The Insights view in Settings queries the
/// persisted log to render "when did X fire?" charts.
public struct DiagnosisIncident: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let title: String
    public let peakSeverity: Severity
    public let firstSeenAt: Date
    public let lastSeenAt: Date
    public let culprits: [String]

    public var durationSeconds: Int {
        max(0, Int(lastSeenAt.timeIntervalSince(firstSeenAt)))
    }

    public init(
        id: UUID = UUID(),
        title: String,
        peakSeverity: Severity,
        firstSeenAt: Date,
        lastSeenAt: Date,
        culprits: [String] = []
    ) {
        self.id = id
        self.title = title
        self.peakSeverity = peakSeverity
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.culprits = culprits
    }
}

/// On-disk, append-mostly log of closed diagnosis incidents. Backs the
/// Insights charts. Written by the sampling pipeline on incident close,
/// read by the settings UI on view appear.
///
/// **Storage:** one JSON file. Entire log rewritten on each append —
/// simple, atomic, no partial-write worry. At 10k incidents × ~300
/// bytes/each the file caps at ~3 MB, small enough that the rewrite
/// cost stays sub-millisecond.
///
/// **Retention:** two caps that both apply:
///   - by time: drop entries older than `retentionDays`
///   - by count: keep at most `maxEntries` (whichever bound bites first)
///
/// Both bounds prevent runaway growth if the user leaves Whirr running
/// for a year on a stressed machine.
public final class IncidentLog: @unchecked Sendable {
    /// Default location for the persisted log. Same directory as
    /// snapshot.json (though that's daemon-written and this is app-written)
    /// so `~/Library/Application Support/Whirr/` collects all Whirr state.
    public static let defaultPath: String = {
        let home = NSHomeDirectory()
        return home + "/Library/Application Support/Whirr/incidents.json"
    }()

    public static let defaultRetentionDays = 30
    public static let defaultMaxEntries = 10_000

    private let path: String
    private let retentionDays: Int
    private let maxEntries: Int
    private let lock = NSLock()
    /// In-memory mirror. Loaded lazily on first access, then kept in
    /// sync on each append. The Insights view reads through this cache
    /// so charting doesn't hit disk each time the window opens.
    private var cached: [DiagnosisIncident]?

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(
        path: String = IncidentLog.defaultPath,
        retentionDays: Int = IncidentLog.defaultRetentionDays,
        maxEntries: Int = IncidentLog.defaultMaxEntries
    ) {
        self.path = path
        self.retentionDays = retentionDays
        self.maxEntries = maxEntries
    }

    /// Append one incident. Purges entries older than the retention
    /// window in the same operation so the file never grows unbounded.
    public func record(_ incident: DiagnosisIncident) {
        lock.withLock {
            var current = loadedLocked()
            current.append(incident)
            let now = incident.lastSeenAt
            current = purge(current, now: now)
            persistLocked(current)
            cached = current
        }
    }

    /// Return all currently-retained incidents, newest last.
    /// Chart code calls this on view appear and reactively when
    /// something new lands (via the `changed` publisher-alike below).
    public func all() -> [DiagnosisIncident] {
        lock.withLock { loadedLocked() }
    }

    /// Return incidents whose first-seen falls within `[from, to]`.
    /// Callers use it to build day-by-day chart buckets.
    public func incidents(from: Date, to: Date) -> [DiagnosisIncident] {
        all().filter { $0.firstSeenAt >= from && $0.firstSeenAt <= to }
    }

    // MARK: - Persistence (lock held)

    private func loadedLocked() -> [DiagnosisIncident] {
        if let cached { return cached }
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url, options: .uncached) else {
            cached = []
            return []
        }
        let loaded = (try? Self.decoder.decode(Envelope.self, from: data))?.incidents ?? []
        cached = loaded
        return loaded
    }

    private func persistLocked(_ incidents: [DiagnosisIncident]) {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let envelope = Envelope(formatVersion: 1, incidents: incidents)
        guard let data = try? Self.encoder.encode(envelope) else { return }
        // Atomic write so a crash mid-save can't corrupt the file.
        try? data.write(to: url, options: [.atomic])
    }

    private func purge(_ incidents: [DiagnosisIncident], now: Date) -> [DiagnosisIncident] {
        let cutoff = now.addingTimeInterval(-Double(retentionDays * 86_400))
        var kept = incidents.filter { $0.firstSeenAt >= cutoff }
        if kept.count > maxEntries {
            // Sort by firstSeenAt ascending before applying the cap. The
            // in-memory cache is naturally ordered by append time (which
            // matches firstSeenAt for typical use) but a file that was
            // edited externally or written by a previous version could
            // arrive unsorted; suffix() on an unsorted array would keep
            // arbitrary entries rather than the newest.
            kept.sort { $0.firstSeenAt < $1.firstSeenAt }
            kept = Array(kept.suffix(maxEntries))
        }
        return kept
    }

    /// Wire-format envelope. `formatVersion` lets us evolve without
    /// misreading old files — an unknown version means "start fresh."
    private struct Envelope: Codable {
        let formatVersion: Int
        let incidents: [DiagnosisIncident]
    }
}
