import Foundation

public struct NetworkQualityResult: Codable, Sendable, Equatable {
    public let downMbps: Double?
    public let upMbps: Double?
    /// Latency with the connection quiet.
    public let idleLatencyMs: Double?
    /// Latency while the connection is saturated (from responsiveness RPM).
    public let loadedLatencyMs: Double?

    public init(downMbps: Double?, upMbps: Double?, idleLatencyMs: Double?, loadedLatencyMs: Double?) {
        self.downMbps = downMbps
        self.upMbps = upMbps
        self.idleLatencyMs = idleLatencyMs
        self.loadedLatencyMs = loadedLatencyMs
    }
}

public struct ConnectionTestResult: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let at: Date
    public let networkId: String?
    /// nil when `networkQuality` couldn't run (offline, missing, timed out).
    public let nq: NetworkQualityResult?
    public let gatewayIdle: HopStats
    /// Router-hop latency measured while networkQuality saturated the
    /// line — the piece that tells Wi-Fi bloat from ISP/router bloat.
    public let gatewayLoaded: HopStats
    public let link: WiFiLink?
    public let neighbors: [NeighborCount]

    public init(id: UUID = UUID(), at: Date, networkId: String?, nq: NetworkQualityResult?,
                gatewayIdle: HopStats, gatewayLoaded: HopStats, link: WiFiLink?, neighbors: [NeighborCount]) {
        self.id = id
        self.at = at
        self.networkId = networkId
        self.nq = nq
        self.gatewayIdle = gatewayIdle
        self.gatewayLoaded = gatewayLoaded
        self.link = link
        self.neighbors = neighbors
    }
}

/// The user-triggered "Check my connection" test (~30 s, ~500 MB).
/// Never run automatically.
public actor ConnectionTestRunner {
    public enum Phase: Sendable, Equatable {
        case measuringIdle, loading, scanning, done
    }

    static let networkQualityPath = "/usr/bin/networkQuality"
    /// Passed as `-M`: networkQuality's own runtime cap.
    static let loadSeconds = 20
    /// Hard stop for the whole subprocess if it hangs.
    static let processTimeout: TimeInterval = 60
    static let idleSeconds: TimeInterval = 5
    static let pingInterval: TimeInterval = 0.2

    private let pinger: Pinging
    private let wifi: WiFiReading
    private let gateway: @Sendable () -> GatewayInfo?

    public init(
        pinger: Pinging = ICMPPinger(),
        wifi: WiFiReading = CoreWLANReader(),
        gateway: @escaping @Sendable () -> GatewayInfo? = { GatewayResolver.current() }
    ) {
        self.pinger = pinger
        self.wifi = wifi
        self.gateway = gateway
    }

    public func run(onPhase: @escaping @Sendable (Phase) -> Void) async -> ConnectionTestResult {
        let gw = gateway()
        let start = Date()

        onPhase(.measuringIdle)
        let idle = await pingGateway(gw?.ip, until: { Date().timeIntervalSince(start) >= Self.idleSeconds })

        onPhase(.loading)
        let process = NetworkQualityProcess(path: Self.networkQualityPath, seconds: Self.loadSeconds, timeout: Self.processTimeout)
        async let nqData = process.run()
        let loaded = await pingGateway(gw?.ip, until: { process.isFinished })
        let nq = await nqData.flatMap(Self.parse(networkQualityJSON:))

        onPhase(.scanning)
        let link = wifi.currentLink()
        let neighbors = link == nil ? [] : wifi.scanNeighbors()

        onPhase(.done)
        return ConnectionTestResult(at: start, networkId: gw?.networkId, nq: nq,
                                    gatewayIdle: idle, gatewayLoaded: loaded, link: link, neighbors: neighbors)
    }

    private func pingGateway(_ ip: String?, until done: @Sendable () -> Bool) async -> HopStats {
        guard let ip else {
            while !done() { try? await Task.sleep(for: .milliseconds(200)) }
            return .empty
        }
        var stats = ConnectionStats()
        let begin = Date()
        while !done() {
            let rtt = await pinger.ping(ip, timeout: 1)
            stats.record(PingSample(at: Date(), hop: .gateway, rttMs: rtt), networkId: ip)
            try? await Task.sleep(for: .milliseconds(Int(Self.pingInterval * 1000)))
        }
        return stats.stats(hop: .gateway, window: Date().timeIntervalSince(begin) + 1, now: Date())
    }

    /// Parses `networkQuality -c` output. Throughputs are bits/s;
    /// `responsiveness` is round-trips per minute under load.
    public static func parse(networkQualityJSON data: Data) -> NetworkQualityResult? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func double(_ key: String) -> Double? { (obj[key] as? NSNumber)?.doubleValue }
        let rpm = double("responsiveness")
        return NetworkQualityResult(
            downMbps: double("dl_throughput").map { $0 / 1_000_000 },
            upMbps: double("ul_throughput").map { $0 / 1_000_000 },
            idleLatencyMs: double("base_rtt"),
            loadedLatencyMs: rpm.flatMap { $0 > 0 ? 60_000 / $0 : nil }
        )
    }
}

/// Runs `networkQuality -c -M <seconds>` and returns stdout, or nil on
/// failure/timeout. `isFinished` lets the caller ping alongside it.
final class NetworkQualityProcess: @unchecked Sendable {
    private let path: String
    private let seconds: Int
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var finished = false

    init(path: String, seconds: Int, timeout: TimeInterval) {
        self.path = path
        self.seconds = seconds
        self.timeout = timeout
    }

    var isFinished: Bool { lock.withLock { finished } }

    func run() async -> Data? {
        defer { lock.withLock { finished = true } }
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-c", "-M", String(seconds)]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let timeout = self.timeout
        let killer = Task.detached {
            try? await Task.sleep(for: .seconds(timeout))
            if process.isRunning { process.terminate() }
        }
        let data = await Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        killer.cancel()
        return process.terminationStatus == 0 ? data : nil
    }
}
