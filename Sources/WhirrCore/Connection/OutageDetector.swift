import Foundation

public enum OutageCause: String, Codable, Sendable {
    /// The router itself stopped answering.
    case router
    /// The router was fine but nothing beyond it answered — the
    /// provider's line.
    case isp
    /// The Mac lost its Wi-Fi association.
    case wifiDisconnected
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
    private var pendingSince: Date?
    private var lastAt: Date?

    public init() {}

    /// - Parameter gatewayOK: nil when the router doesn't answer pings at
    ///   all (some block ICMP) — then only the internet hop is judged.
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
            if var open = current {
                open.end = lastAt
                closed = open
                current = nil
            }
        }
        lastAt = now

        guard let cause = Self.cause(gatewayOK: gatewayOK, internetOK: internetOK, wifiAssociated: wifiAssociated) else {
            pendingSince = nil
            if var open = current {
                open.end = now
                current = nil
                return (nil, open)
            }
            return (nil, closed)
        }

        if current != nil { return (nil, closed) }
        guard let since = pendingSince else {
            pendingSince = now
            return (nil, closed)
        }
        guard now.timeIntervalSince(since) >= Self.minDuration else { return (nil, closed) }
        let record = OutageRecord(start: since, cause: cause, networkId: networkId)
        current = record
        pendingSince = nil
        return (record, closed)
    }

    static func cause(gatewayOK: Bool?, internetOK: Bool, wifiAssociated: Bool) -> OutageCause? {
        // Internet reachable means no outage, whatever the Wi-Fi state
        // (a wired Mac has no Wi-Fi association at all).
        if internetOK { return nil }
        if !wifiAssociated { return .wifiDisconnected }
        return gatewayOK == false ? .router : .isp
    }
}
