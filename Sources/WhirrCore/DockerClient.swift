import Foundation
import Network

/// Per-container resource snapshot from Docker's stats API.
/// We only keep the fields Whirr displays; the API returns a lot more.
public struct DockerContainer: Codable, Sendable, Hashable, Identifiable {
    public let id: String                  // 12-char short ID
    public let name: String                // Without the leading slash Docker prefixes
    public let image: String
    public let cpuPercent: Double          // 100% = one core fully used (matches `docker stats`)
    public let memoryBytes: UInt64
    public let memoryLimitBytes: UInt64?
    /// Docker Compose project name from `com.docker.compose.project` label.
    /// Lets the UI group related containers (e.g., a Supabase stack) under
    /// one header instead of five disconnected rows. Nil for containers
    /// started outside of Compose (`docker run` etc.).
    public let composeProject: String?
    /// Container service name from `com.docker.compose.service`. Within a
    /// Compose project, this is the short logical name ("db", "web") —
    /// often more readable than the full container name.
    public let composeService: String?
    /// Container status string from `/containers/json` ("Up 3 hours",
    /// "Restarting (1) 2 seconds ago"). Surfaces age + recent restarts
    /// without us having to compute them.
    public let status: String?

    public init(
        id: String,
        name: String,
        image: String,
        cpuPercent: Double,
        memoryBytes: UInt64,
        memoryLimitBytes: UInt64?,
        composeProject: String? = nil,
        composeService: String? = nil,
        status: String? = nil
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.composeProject = composeProject
        self.composeService = composeService
        self.status = status
    }
}

/// Talks to the Docker daemon via its Unix socket. Used from the menu bar
/// app (the daemon doesn't query Docker because the socket lives in the
/// user's home directory and the launchd-managed sampler can't reliably
/// locate the active user's path).
///
/// Docker is queried with a short timeout so a stopped Docker Desktop or
/// hanging socket never blocks sampling. On any failure the client returns
/// an empty list — the menu bar treats that as "no containers running."
public actor DockerClient {
    public enum ClientError: Error, Sendable {
        case socketUnavailable
        case requestFailed(String)
        case invalidResponse
        case nonOKStatus(String)
    }

    private let candidateSocketPaths: [String]
    private let timeout: TimeInterval
    private var cachedSocketPath: String?

    public init(timeout: TimeInterval = 2.0) {
        // Docker Desktop's modern default lives under the user's home dir;
        // older or system-managed Docker daemons use /var/run/docker.sock.
        // First match wins on `fileExists`.
        let home = NSHomeDirectory()
        candidateSocketPaths = [
            "\(home)/.docker/run/docker.sock",
            "/var/run/docker.sock"
        ]
        self.timeout = timeout
    }

    /// Returns currently running containers with their stats. On failure
    /// (Docker stopped, socket missing, request timeout) returns []. Never
    /// throws — callers should treat the empty list as "no info" rather
    /// than "no containers."
    public func listContainers() async -> [DockerContainer] {
        guard let socketPath = findWorkingSocket() else {
            return []
        }
        do {
            let listData = try await get("/containers/json", socketPath: socketPath)
            let raw = try JSONDecoder().decode([RawContainer].self, from: listData)
            return await withTaskGroup(of: DockerContainer?.self) { group in
                for container in raw {
                    group.addTask { [self] in
                        try? await fetchStats(
                            id: container.Id,
                            name: container.Names.first ?? container.Id,
                            image: container.Image,
                            composeProject: container.Labels?["com.docker.compose.project"],
                            composeService: container.Labels?["com.docker.compose.service"],
                            status: container.Status,
                            socketPath: socketPath
                        )
                    }
                }
                var results: [DockerContainer] = []
                for await result in group {
                    if let r = result { results.append(r) }
                }
                return results.sorted { $0.memoryBytes > $1.memoryBytes }
            }
        } catch {
            // A failed list call usually means Docker stopped. Drop the
            // cached socket path so the next call re-probes.
            cachedSocketPath = nil
            return []
        }
    }

    private func findWorkingSocket() -> String? {
        if let cached = cachedSocketPath, FileManager.default.fileExists(atPath: cached) {
            return cached
        }
        cachedSocketPath = nil
        for path in candidateSocketPaths where FileManager.default.fileExists(atPath: path) {
            cachedSocketPath = path
            return path
        }
        return nil
    }

    private func fetchStats(
        id: String,
        name: String,
        image: String,
        composeProject: String?,
        composeService: String?,
        status: String?,
        socketPath: String
    ) async throws -> DockerContainer? {
        let data = try await get("/containers/\(id)/stats?stream=false", socketPath: socketPath)
        let raw = try JSONDecoder().decode(RawStats.self, from: data)

        let cpuPercent = Self.computeCPUPercent(stats: raw)
        let cleanName = name.hasPrefix("/") ? String(name.dropFirst()) : name
        let shortId = String(id.prefix(12))
        return DockerContainer(
            id: shortId,
            name: cleanName,
            image: image,
            cpuPercent: cpuPercent,
            memoryBytes: raw.memory_stats.usage ?? 0,
            memoryLimitBytes: raw.memory_stats.limit,
            composeProject: composeProject,
            composeService: composeService,
            status: status
        )
    }

    /// Mirrors `docker stats`'s percentage column: 100% = one core. Multi-core
    /// containers can exceed 100%. Returns 0 if either delta is zero — that
    /// happens on the very first stats call for a freshly started container.
    static func computeCPUPercent(stats raw: RawStats) -> Double {
        let cpuDelta = Double(raw.cpu_stats.cpu_usage.total_usage)
            - Double(raw.precpu_stats.cpu_usage.total_usage)
        let systemDelta = Double(raw.cpu_stats.system_cpu_usage ?? 0)
            - Double(raw.precpu_stats.system_cpu_usage ?? 0)
        guard systemDelta > 0, cpuDelta > 0 else { return 0 }
        let onlineCpus = Double(
            raw.cpu_stats.online_cpus
                ?? raw.cpu_stats.cpu_usage.percpu_usage?.count
                ?? 1
        )
        return (cpuDelta / systemDelta) * onlineCpus * 100.0
    }

    // MARK: - Container actions

    /// Send SIGTERM (then SIGKILL after Docker's default timeout) to the
    /// container. The container's main process exits cleanly if it handles
    /// the signal. Useful for "I'm done with this dev DB" scenarios.
    ///
    /// Uses a longer timeout than reads (15 s) because Docker waits up to
    /// 10 s for graceful shutdown before responding.
    public func stop(containerId: String) async throws {
        guard let socketPath = findWorkingSocket() else { throw ClientError.socketUnavailable }
        _ = try await post("/containers/\(containerId)/stop", socketPath: socketPath, timeoutOverride: 15.0)
    }

    /// Stop then start the container. Equivalent to `docker restart <id>`.
    public func restart(containerId: String) async throws {
        guard let socketPath = findWorkingSocket() else { throw ClientError.socketUnavailable }
        _ = try await post("/containers/\(containerId)/restart", socketPath: socketPath, timeoutOverride: 15.0)
    }

    // MARK: - HTTP over Unix socket

    private func get(_ path: String, socketPath: String) async throws -> Data {
        let raw = try await rawRequest(method: "GET", path: path, socketPath: socketPath)
        return try Self.parseHTTPBody(raw)
    }

    private func post(_ path: String, socketPath: String, timeoutOverride: TimeInterval? = nil) async throws -> Data {
        let raw = try await rawRequest(method: "POST", path: path, socketPath: socketPath, timeoutOverride: timeoutOverride)
        return try Self.parseHTTPBody(raw)
    }

    private func rawRequest(method: String, path: String, socketPath: String, timeoutOverride: TimeInterval? = nil) async throws -> Data {
        // Content-Length: 0 keeps Docker happy on POSTs with no body —
        // some endpoints (stop, restart) accept no payload, others require
        // an explicit zero length to avoid hanging waiting for a body.
        let request = "\(method) \(path) HTTP/1.0\r\nHost: localhost\r\nAccept: application/json\r\nContent-Length: 0\r\n\r\n"
        guard let requestData = request.data(using: .utf8) else {
            throw ClientError.invalidResponse
        }
        let session = SocketSession(socketPath: socketPath, timeout: timeoutOverride ?? timeout)
        return try await session.run(sending: requestData)
    }

    /// A single HTTP-over-unix-socket request. Owns its NWConnection from
    /// start to finish; the continuation is resumed exactly once via a
    /// dedicated dispatch queue (all callbacks land here) and a guard flag.
    private final class SocketSession: @unchecked Sendable {
        private let connection: NWConnection
        private let queue: DispatchQueue
        private let timeout: TimeInterval
        private var didResume = false
        private var accumulator = Data()
        private var continuation: CheckedContinuation<Data, Error>?

        init(socketPath: String, timeout: TimeInterval) {
            let endpoint = NWEndpoint.unix(path: socketPath)
            self.connection = NWConnection(to: endpoint, using: .tcp)
            self.queue = DispatchQueue(label: "DockerClient.SocketSession")
            self.timeout = timeout
        }

        func run(sending data: Data) async throws -> Data {
            return try await withCheckedThrowingContinuation { cont in
                self.continuation = cont
                connection.stateUpdateHandler = { [weak self] state in
                    self?.handle(state: state, send: data)
                }
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(ClientError.requestFailed("timeout")))
                }
                connection.start(queue: queue)
            }
        }

        private func handle(state: NWConnection.State, send data: Data) {
            switch state {
            case .ready:
                connection.send(content: data, completion: .contentProcessed { [weak self] err in
                    if let err = err { self?.finish(.failure(err)) }
                })
                receiveNext()
            case .failed(let err):
                finish(.failure(err))
            case .cancelled:
                finish(.failure(ClientError.requestFailed("cancelled")))
            default:
                break
            }
        }

        private func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, err in
                guard let self else { return }
                if let err = err {
                    self.finish(.failure(err))
                    return
                }
                if let data = data { self.accumulator.append(data) }
                if isComplete {
                    self.finish(.success(self.accumulator))
                    return
                }
                self.receiveNext()
            }
        }

        private func finish(_ result: Result<Data, Error>) {
            guard !didResume else { return }
            didResume = true
            connection.cancel()
            switch result {
            case .success(let d): continuation?.resume(returning: d)
            case .failure(let e): continuation?.resume(throwing: e)
            }
            continuation = nil
        }
    }

    static func parseHTTPBody(_ data: Data) throws -> Data {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw ClientError.invalidResponse
        }
        let headerData = data.subdata(in: 0..<separator.lowerBound)
        guard let headers = String(data: headerData, encoding: .utf8) else {
            throw ClientError.invalidResponse
        }
        let statusLine = headers.split(separator: "\r\n", maxSplits: 1).first ?? ""
        // Accept any 2xx — Docker returns 204 No Content for stop/restart,
        // 200 OK for list/stats, and 304 Not Modified if the action would
        // be a no-op (already stopped, already in the desired state).
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw ClientError.nonOKStatus(String(statusLine))
        }
        if status == 304 { return Data() }  // No-op success
        guard (200..<300).contains(status) else {
            throw ClientError.nonOKStatus(String(statusLine))
        }
        return data.subdata(in: separator.upperBound..<data.count)
    }

    // MARK: - Docker wire format

    struct RawContainer: Decodable {
        let Id: String
        let Names: [String]
        let Image: String
        let Status: String?
        let Labels: [String: String]?
    }

    struct RawStats: Decodable {
        struct CPU: Decodable {
            struct Usage: Decodable {
                let total_usage: UInt64
                let percpu_usage: [UInt64]?
            }
            let cpu_usage: Usage
            let system_cpu_usage: UInt64?
            let online_cpus: Int?
        }
        struct Memory: Decodable {
            let usage: UInt64?
            let limit: UInt64?
        }
        let cpu_stats: CPU
        let precpu_stats: CPU
        let memory_stats: Memory
    }
}
