import Foundation

/// Reads Harbr's on-disk config so Whirr can attribute processes to
/// specific dev-server projects. Harbr writes a superset of the JSON we
/// need; we decode only `name` + `port` (+ `group`), ignore everything
/// else, and are forward-compatible with Harbr adding fields.
///
/// Design: no watch, no observer. Called once at Whirr startup and then
/// again on a slow refresh cadence (every minute) from SystemMonitor.
/// Harbr edits are rare — the user adds a project once and forgets. A
/// missing/malformed file is a first-class outcome, not an error.
public struct HarbrConfigReader: Sendable {

    /// Absolute path to Harbr's config. Same location Harbr writes to:
    /// see `Harbr/Sources/Harbr/main.swift` — hardcoded there too.
    public static let defaultPath: String = {
        let home = ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectory()
        return home + "/.harbr/config.json"
    }()

    public enum LoadOutcome: Sendable, Equatable {
        case loaded([HarbrProject])
        case absent
        case malformed(reason: String)

        public var projects: [HarbrProject] {
            if case .loaded(let p) = self { return p } else { return [] }
        }
    }

    private let path: String

    public init(path: String = HarbrConfigReader.defaultPath) {
        self.path = path
    }

    /// Reads the config from disk. Never throws — every failure surfaces
    /// as `.absent` or `.malformed`, and the app treats both as "no Harbr
    /// integration this tick."
    public func load() -> LoadOutcome {
        // FileManager.default is used directly rather than injected. It's
        // effectively immutable and Sendable-safe in practice; the read
        // is idempotent and side-effect-free.
        guard FileManager.default.fileExists(atPath: path) else { return .absent }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .uncached) else {
            return .malformed(reason: "unreadable")
        }
        do {
            let decoded = try JSONDecoder().decode(Envelope.self, from: data)
            // Deduplicate by port — same port twice would break attribution.
            // Keep the first occurrence; Harbr itself rejects duplicates on
            // write so this is defense in depth.
            var seenPorts: Set<Int> = []
            let projects = decoded.projects.compactMap { p -> HarbrProject? in
                guard p.port > 0 && p.port < 65536 else { return nil }
                guard !seenPorts.contains(p.port) else { return nil }
                seenPorts.insert(p.port)
                return HarbrProject(name: p.name, port: p.port, group: p.group)
            }
            return .loaded(projects)
        } catch {
            return .malformed(reason: String(describing: error))
        }
    }

    /// Convenience — returns just the projects, or [] on any failure.
    /// Callers that need to distinguish absent/malformed use `load()`.
    public func projects() -> [HarbrProject] {
        load().projects
    }

    /// Internal decoding shape. We decode only the fields we need; extra
    /// keys in Harbr's config file are silently ignored, which is what we
    /// want for forward compatibility.
    private struct Envelope: Decodable {
        let projects: [ProjectDTO]
    }
    private struct ProjectDTO: Decodable {
        let name: String
        let port: Int
        let group: String?
    }
}

/// Pure map operation: given the Harbr project list and the current
/// process sample list, produce a `HarbrProjectStatus` per project.
///
/// Attribution strategy: try the process table first. Any process whose
/// command line references `-p PORT`, `--port PORT`, or `:PORT` and that
/// matches a Harbr project's port is that project's holder. On miss we
/// fall back to a quick TCP connect to `127.0.0.1:PORT` — same probe
/// Harbr itself uses — to detect "something is listening but we couldn't
/// attribute the pid" (common for Docker-composed stacks where the port
/// is held by com.docker.backend, not the user's shell).
///
/// This is a free-function rather than a method on HarbrConfigReader
/// because it depends on ProcessSample (rules-engine-level data) that
/// the reader has no business knowing about.
public enum HarbrAttribution {
    public static func statuses(
        projects: [HarbrProject],
        processes: [ProcessSample],
        portListening: (Int) -> Bool = defaultPortListening
    ) -> [HarbrProjectStatus] {
        var statuses: [HarbrProjectStatus] = []
        statuses.reserveCapacity(projects.count)

        for project in projects {
            let matched = processes.first { matches(process: $0, port: project.port) }
            if let m = matched {
                statuses.append(HarbrProjectStatus(
                    project: project,
                    isRunning: true,
                    pid: m.pid,
                    processName: m.name,
                    cpuPercent: m.cpuPercent,
                    memoryBytes: m.memoryBytes
                ))
            } else if portListening(project.port) {
                statuses.append(HarbrProjectStatus(
                    project: project,
                    isRunning: true
                ))
            } else {
                statuses.append(HarbrProjectStatus(
                    project: project,
                    isRunning: false
                ))
            }
        }
        return statuses
    }

    /// Matches a process to a port by scanning its command line. Common
    /// patterns:
    ///   `next dev -p 3000`
    ///   `next dev --port 3000`
    ///   `vite --port=3000`
    ///   `python -m http.server 8000`
    ///   `node server.js --port 3005`
    ///   `docker-proxy -host-ip 0.0.0.0 -host-port 54323 ...`
    /// We don't try to be exhaustive — the fallback port-listening probe
    /// catches whatever this misses.
    static func matches(process: ProcessSample, port: Int) -> Bool {
        guard let cmd = process.commandLine, !cmd.isEmpty else { return false }
        let needle = String(port)
        // Whole-token boundary: don't match `3000` inside `30000`. Scan
        // for the port number wherever it appears preceded/followed by
        // non-digit or start/end of string.
        let cs = Array(cmd)
        var i = 0
        while i < cs.count {
            if let range = matchAt(cs, index: i, needle: needle) {
                let before = range.lowerBound == 0 ? nil : cs[range.lowerBound - 1]
                let after = range.upperBound == cs.count ? nil : cs[range.upperBound]
                let leftOK = before.map { !$0.isNumber } ?? true
                let rightOK = after.map { !$0.isNumber } ?? true
                if leftOK && rightOK { return true }
                i = range.upperBound
            } else {
                i += 1
            }
        }
        return false
    }

    private static func matchAt(_ cs: [Character], index i: Int, needle: String) -> Range<Int>? {
        let ns = Array(needle)
        guard i + ns.count <= cs.count else { return nil }
        for j in 0..<ns.count where cs[i + j] != ns[j] { return nil }
        return i..<(i + ns.count)
    }

    /// Default port-listening probe. Non-blocking connect + `poll(2)` for
    /// writability so we can honor a tight timeout without pulling in
    /// Network.framework's async machinery. A full scan of ~20 Harbr
    /// ports takes well under 100 ms even if some are firewall-dropped.
    /// Loopback-only because Harbr's model is local-only.
    public static func defaultPortListening(_ port: Int) -> Bool {
        var sockAddr = sockaddr_in()
        sockAddr.sin_family = sa_family_t(AF_INET)
        sockAddr.sin_port = in_port_t(port).bigEndian
        // 127.0.0.1 as network-byte-order UInt32.
        sockAddr.sin_addr.s_addr = in_addr_t(0x7F000001).bigEndian

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        let result = withUnsafePointer(to: &sockAddr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                connect(sock, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        if errno != EINPROGRESS { return false }

        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let ready = withUnsafeMutablePointer(to: &pfd) { p in
            poll(p, 1, 50)  // 50 ms
        }
        guard ready > 0 else { return false }

        // Distinguish "connect completed successfully" from "connect
        // failed asynchronously (ECONNREFUSED)" — both wake poll on
        // writability. SO_ERROR is 0 on success.
        var soErr: Int32 = 0
        var soErrLen = socklen_t(MemoryLayout<Int32>.size)
        _ = getsockopt(sock, SOL_SOCKET, SO_ERROR, &soErr, &soErrLen)
        return soErr == 0
    }
}
