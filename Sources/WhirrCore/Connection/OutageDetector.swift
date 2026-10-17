import Foundation

public enum OutageCause: String, Codable, Sendable {
    /// The router itself stopped answering.
    case router
    /// The router was fine but nothing beyond it answered — the
    /// provider's line.
    case isp
    /// The Mac lost its Wi-Fi association.
    case wifiDisconnected
    /// Nothing answered, and the router has never been confirmed to
    /// answer pings — so Whirr can't say which side failed.
    case unknown
}

public struct OutageRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let start: Date
    public var end: Date?
    public let cause: OutageCause
    public let networkId: String

    public init(id: UUID = UUID(), start: Date, end: Date? = nil, cause: OutageCause, networkId: String) {
        self.id = id
        self.start = start
        self.end = end
        self.cause = cause
        self.networkId = networkId
    }

    public var duration: TimeInterval? { end.map { $0.timeIntervalSince(start) } }
}

/// Turns per-round ping results into outage records with a cause.
public struct OutageDetector: Sendable {
    /// Failures must persist this long to count — shorter is a blip.
    public static let minDuration: TimeInterval = 10
    /// A gap this long between observations means the Mac slept (or the
    /// monitor paused). Never treat sleep as connection failure.
    public static let sleepGap: TimeInterval = 30

    public private(set) var current: OutageRecord?
    /// Failing, but not for long enough to call it an outage yet.
    public var isPending: Bool { pendingSince != nil }
    private var pendingSince: Date?
    /// What each failing round in the pending window pointed to. The
    /// recorded cause is the clear majority — one lost router ping during
    /// a line outage mustn't relabel it "router".
    private var votes: [OutageCause: Int] = [:]
    private var lastAt: Date?
    /// A cause needs this share of the failing rounds; otherwise the
    /// evidence is mixed and the outage is recorded as `.unknown`.
    static let majorityShare = 2.0 / 3.0

    public init() {}

    /// - Parameter gatewayOK: nil when the router hasn't been confirmed to
    ///   answer pings (some block ICMP) — then failures are `.unknown`.
    public mutating func observe(
        gatewayOK: Bool?,
        internetOK: Bool,
        wifiAssociated: Bool,
        at now: Date,
        networkId: String
    ) -> (opened: OutageRecord?, closed: OutageRecord?) {
        var closed: OutageRecord?
        if let lastAt, now.timeIntervalSince(lastAt) > Self.sleepGap {
            pendingSince = nil
            votes = [:]
            if var open = current {
                open.end = lastAt
                closed = open
                current = nil
            }
        }
        lastAt = now

        guard let cause = Self.cause(gatewayOK: gatewayOK, internetOK: internetOK, wifiAssociated: wifiAssociated) else {
            pendingSince = nil
            votes = [:]
            if var open = current {
                open.end = now
                current = nil
                return (nil, open)
            }
            return (nil, closed)
        }

        if current != nil { return (nil, closed) }
        votes[cause, default: 0] += 1
        guard let since = pendingSince else {
            pendingSince = now
            return (nil, closed)
        }
        guard now.timeIntervalSince(since) >= Self.minDuration else { return (nil, closed) }
        let record = OutageRecord(start: since, cause: majorityCause(), networkId: networkId)
        current = record
        pendingSince = nil
        votes = [:]
        return (record, closed)
    }

    private func majorityCause() -> OutageCause {
        let total = votes.values.reduce(0, +)
        guard let top = votes.max(by: { $0.value < $1.value }), total > 0,
              Double(top.value) / Double(total) >= Self.majorityShare else { return .unknown }
        return top.key
    }

    static func cause(gatewayOK: Bool?, internetOK: Bool, wifiAssociated: Bool) -> OutageCause? {
        // Internet reachable means no outage, whatever the Wi-Fi state
        // (a wired Mac has no Wi-Fi association at all).
        if internetOK { return nil }
        if !wifiAssociated { return .wifiDisconnected }
        switch gatewayOK {
        case .some(false): return .router
        case .some(true): return .isp
        // Router unverified: claiming either side would be a guess.
        case .none: return .unknown
        }
    }
}

extension OutageCause {
    /// One line for the Overview tile and the Connection header. Each
    /// cause says only what was observed.
    public var summary: String {
        switch self {
        case .router: return "Router isn't responding."
        case .isp: return "Internet is down beyond your router (the router answers)."
        case .wifiDisconnected: return "Wi-Fi disconnected."
        case .unknown: return "Connection is down."
        }
    }
}
