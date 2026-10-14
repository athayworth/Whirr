import Foundation

/// One minute of connection history — what the per-channel comparison
/// and History charts are built from.
public struct MinuteAggregate: Codable, Sendable, Equatable {
    public let minute: Date
    public let networkId: String
    public let gateway: HopStats
    public let internet: HopStats
    public let channel: Int?
    public let band: String?
    public let rssi: Int?
    public let noise: Int?

    public init(minute: Date, networkId: String, gateway: HopStats, internet: HopStats,
                channel: Int?, band: String?, rssi: Int?, noise: Int?) {
        self.minute = minute
        self.networkId = networkId
        self.gateway = gateway
        self.internet = internet
        self.channel = channel
        self.band = band
        self.rssi = rssi
        self.noise = noise
    }
}

/// Persists connection history under `~/Library/Application Support/Whirr/`.
/// Minute aggregates are an append-only JSON-lines file (cheap to append
/// every minute); outages are a small JSON array rewritten on change.
public final class ConnectionHistoryStore: @unchecked Sendable {
    public static let retention: TimeInterval = 30 * 86_400

    private let directory: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private var historyURL: URL { directory.appendingPathComponent("connection-history.jsonl") }
    private var outagesURL: URL { directory.appendingPathComponent("outages.json") }
    private var testsURL: URL { directory.appendingPathComponent("connection-tests.json") }
    static let maxSavedTests = 50

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Whirr", isDirectory: true)
    }

    public init(directory: URL = ConnectionHistoryStore.defaultDirectory) {
        self.directory = directory
    }

    // MARK: Minute aggregates

    public func append(_ aggregate: MinuteAggregate) {
        guard var line = try? encoder.encode(aggregate) else { return }
        line.append(0x0A)
        lock.withLock {
            ensureDirectory()
            if let handle = try? FileHandle(forWritingTo: historyURL) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            } else {
                try? line.write(to: historyURL, options: .atomic)
            }
        }
    }

    public func aggregates(since: Date) -> [MinuteAggregate] {
        lock.withLock { readAggregates() }.filter { $0.minute >= since }
    }

    // MARK: Outages

    public func appendOutage(_ outage: OutageRecord) {
        lock.withLock {
            var all = readOutages()
            all.append(outage)
            writeOutages(all)
        }
    }

    public func updateOutage(_ outage: OutageRecord) {
        lock.withLock {
            var all = readOutages()
            if let i = all.firstIndex(where: { $0.id == outage.id }) {
                all[i] = outage
            } else {
                all.append(outage)
            }
            writeOutages(all)
        }
    }

    /// Closes outages left open by a quit, crash or reboot, so they don't
    /// read as "ongoing" forever (or in the summary for the provider).
    public func closeDanglingOutages(at end: Date) {
        lock.withLock {
            let all = readOutages()
            guard all.contains(where: { $0.end == nil }) else { return }
            writeOutages(all.map { o in
                var o = o
                if o.end == nil { o.end = max(end, o.start) }
                return o
            })
        }
    }

    public func outages() -> [OutageRecord] {
        lock.withLock { readOutages() }
    }

    // MARK: Full test results

    public func saveTest(_ result: ConnectionTestResult) {
        lock.withLock {
            var all = readTests()
            all.append(result)
            all = Array(all.suffix(Self.maxSavedTests))
            ensureDirectory()
            if let data = try? encoder.encode(all) { try? data.write(to: testsURL, options: .atomic) }
        }
    }

    /// Saved results, oldest first.
    public func tests() -> [ConnectionTestResult] {
        lock.withLock { readTests() }
    }

    private func readTests() -> [ConnectionTestResult] {
        guard let data = try? Data(contentsOf: testsURL) else { return [] }
        return (try? decoder.decode([ConnectionTestResult].self, from: data)) ?? []
    }

    // MARK: Retention

    public func purge(olderThan cutoff: Date) {
        lock.withLock {
            let kept = readAggregates().filter { $0.minute >= cutoff }
            let lines = kept.compactMap { try? encoder.encode($0) }
            var data = Data()
            for line in lines { data.append(line); data.append(0x0A) }
            ensureDirectory()
            try? data.write(to: historyURL, options: .atomic)
            writeOutages(readOutages().filter { $0.start >= cutoff })
        }
    }

    // MARK: Private (call with lock held)

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func readAggregates() -> [MinuteAggregate] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        // A torn or corrupt line (crash mid-write) is skipped, not fatal.
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(MinuteAggregate.self, from: Data($0)) }
    }

    private func readOutages() -> [OutageRecord] {
        guard let data = try? Data(contentsOf: outagesURL) else { return [] }
        return (try? decoder.decode([OutageRecord].self, from: data)) ?? []
    }

    private func writeOutages(_ outages: [OutageRecord]) {
        ensureDirectory()
        guard let data = try? encoder.encode(outages) else { return }
        try? data.write(to: outagesURL, options: .atomic)
    }
}
