import Foundation

/// Summary of one hop's pings over a time window.
public struct HopStats: Codable, Sendable, Equatable {
    public let count: Int
    /// Typical round-trip time.
    public let medianMs: Double?
    /// "Bad moments" round-trip time — 1 in 20 pings was slower.
    public let p95Ms: Double?
    /// How uneven the connection is: mean change between consecutive pings.
    public let jitterMs: Double?
    public let lossPercent: Double
    /// Timeouts plus pings far slower than typical (see `isSpike`).
    public let spikes: Int

    public init(count: Int, medianMs: Double?, p95Ms: Double?, jitterMs: Double?, lossPercent: Double, spikes: Int) {
        self.count = count
        self.medianMs = medianMs
        self.p95Ms = p95Ms
        self.jitterMs = jitterMs
        self.lossPercent = lossPercent
        self.spikes = spikes
    }

    public static let empty = HopStats(count: 0, medianMs: nil, p95Ms: nil, jitterMs: nil, lossPercent: 0, spikes: 0)
}

/// Rolling in-memory ping history for the current network.
public struct ConnectionStats: Sendable {
    private let retention: TimeInterval
    private var samples: [PingSample] = []
    private var networkId: String?

    public init(retention: TimeInterval = 3600) {
        self.retention = retention
    }

    public mutating func record(_ sample: PingSample, networkId: String) {
        // A different router means a different network — its pings say
        // nothing about home, so start over rather than mix them.
        if networkId != self.networkId {
            samples.removeAll(keepingCapacity: true)
            self.networkId = networkId
        }
        samples.append(sample)
        let cutoff = sample.at.addingTimeInterval(-retention)
        if let firstKept = samples.firstIndex(where: { $0.at > cutoff }), firstKept > 0 {
            samples.removeFirst(firstKept)
        }
    }

    public func stats(hop: Hop, window: TimeInterval, now: Date) -> HopStats {
        let since = now.addingTimeInterval(-window)
        let inWindow = samples.filter { $0.hop == hop && $0.at > since && $0.at <= now }
        guard !inWindow.isEmpty else { return .empty }
        let rtts = inWindow.compactMap(\.rttMs)
        let sorted = rtts.sorted()
        let median = Self.median(sorted)
        let p95 = sorted.isEmpty ? nil : sorted[max(0, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        let jitter: Double? = rtts.count < 2 ? nil
            : zip(rtts, rtts.dropFirst()).map { abs($1 - $0) }.reduce(0, +) / Double(rtts.count - 1)
        let loss = Double(inWindow.count - rtts.count) / Double(inWindow.count) * 100
        let spikes = median.map { m in inWindow.filter { Self.isSpike($0.rttMs, median: m) }.count }
            ?? inWindow.count  // every ping timed out
        return HopStats(count: inWindow.count, medianMs: median, p95Ms: p95, jitterMs: jitter,
                        lossPercent: loss, spikes: spikes)
    }

    /// A spike is a timeout, or a ping well beyond typical: more than
    /// triple the median *and* at least 50 ms above it. The 50 ms floor
    /// stops a 2 → 7 ms wobble on a fast router counting as a spike.
    public static func isSpike(_ rtt: Double?, median: Double) -> Bool {
        guard let rtt else { return true }
        return rtt > max(median * 3, median + 50)
    }

    static func median(_ sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

/// One shared reading of a hop's health, so the live rows, the report
/// card, the daily summary and the findings never disagree.
public enum HopHealth: Sendable, Equatable {
    /// Not enough pings yet to judge.
    case measuring
    /// Under the "clean" limits.
    case steady
    /// Some stalls, below the level the findings warn about.
    case minor
    /// At or above the findings' warning level.
    case stalling

    public init(_ stats: HopStats, config: ConnectionRuleConfig = ConnectionRuleConfig()) {
        if stats.count < config.minSamples {
            self = .measuring
        } else if stats.spikes < config.cleanMaxSpikes && stats.lossPercent < config.cleanMaxLoss {
            self = .steady
        } else if stats.spikes < config.spikyWarnSpikes && stats.lossPercent < config.spikyWarnLoss {
            self = .minor
        } else {
            self = .stalling
        }
    }

    /// Ordered by how much trouble a hop showed; `.measuring` is lowest.
    func isWorse(than other: HopHealth) -> Bool { rank > other.rank }

    private var rank: Int {
        switch self {
        case .measuring: return 0
        case .steady: return 1
        case .minor: return 2
        case .stalling: return 3
        }
    }
}
