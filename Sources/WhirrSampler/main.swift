import Foundation
import WhirrCore

// MARK: - Configuration

/// Hardcoded path the daemon writes to. Validated by `validate(outputPath:)`
/// before any write happens, so a misconfigured launchd plist or a stray
/// command-line override can't redirect output to an arbitrary location.
private let defaultOutputPath = "/Library/Application Support/Whirr/snapshot.json"
private let defaultHistoryPath = "/Library/Application Support/Whirr/history.json"

/// History capacity. At 3 s sampling cadence, 600 points = 30 minutes.
/// Keep this bounded — the file is rewritten every tick and the menu bar
/// reads it every tick, so size matters.
private let historyMaxPoints = 600

/// Output paths must live under this prefix. Refusing other paths means
/// `whirr-sampler --output /etc/passwd` can't be coerced into overwriting
/// system files even when run as root.
private let allowedOutputPrefix = "/Library/Application Support/Whirr/"

private let defaultIntervalSeconds: Double = 3.0
private let minimumIntervalSeconds: Double = 1.0
private let maximumIntervalSeconds: Double = 60.0

// MARK: - Args

struct SamplerOptions {
    var outputPath: String = defaultOutputPath
    var intervalSeconds: Double = defaultIntervalSeconds
    var once: Bool = false
}

func parseArgs(_ args: [String]) -> SamplerOptions? {
    var opts = SamplerOptions()
    var i = 1
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--once":
            opts.once = true
            i += 1
        case "--output":
            guard i + 1 < args.count else { return nil }
            opts.outputPath = args[i + 1]
            i += 2
        case "--interval":
            guard i + 1 < args.count, let v = Double(args[i + 1]) else { return nil }
            opts.intervalSeconds = v
            i += 2
        case "-h", "--help":
            printUsage()
            exit(0)
        default:
            FileHandle.standardError.write(Data("Unknown argument: \(arg)\n".utf8))
            return nil
        }
    }
    return opts
}

func printUsage() {
    let usage = """
    Usage: whirr-sampler [--output PATH] [--interval SECONDS] [--once]

    Samples system + process state every interval and writes a JSON snapshot
    to PATH. Designed to run as root via launchd so it can read CPU/memory/IO
    for all processes (not just the launching user's).

    Defaults:
      --output      \(defaultOutputPath)
      --interval    \(defaultIntervalSeconds) seconds
      --once        emit a single snapshot to stdout (don't loop, don't write)

    Output paths must live under \(allowedOutputPrefix) — this is enforced
    even when run as root, so a misconfigured invocation can't write to
    arbitrary system locations.
    """
    print(usage)
}

func validate(outputPath: String) -> Bool {
    let normalized = (outputPath as NSString).standardizingPath
    return normalized.hasPrefix(allowedOutputPrefix)
}

func validate(interval: Double) -> Bool {
    interval >= minimumIntervalSeconds && interval <= maximumIntervalSeconds
}

// MARK: - Logging

func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(timestamp)] \(message)\n".utf8))
}

// MARK: - Encoding + atomic write

let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

func write(_ payload: SnapshotPayload, to path: String) throws {
    let data = try jsonEncoder.encode(payload)
    let url = URL(fileURLWithPath: path)
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // .atomic writes to a sibling temp file and renames into place, so a
    // reader never sees a partially-written file.
    try data.write(to: url, options: [.atomic])
    // World-readable so the user's menu bar app can pick it up; root-owned.
    try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
}

func write(_ history: TrendHistory, to path: String) throws {
    let data = try jsonEncoder.encode(history)
    let url = URL(fileURLWithPath: path)
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try data.write(to: url, options: [.atomic])
    try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
}

func loadHistoryOrEmpty(from path: String) -> [TrendPoint] {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let history = try? decoder.decode(TrendHistory.self, from: data),
          history.formatVersion == TrendHistory.currentFormatVersion else {
        return []
    }
    return history.points
}

func trendPoint(from payload: SnapshotPayload) -> TrendPoint {
    let worst = payload.diagnoses.map(\.severity).max() ?? .ok
    return TrendPoint(
        capturedAt: payload.capturedAt,
        memoryPressure: payload.snapshot.memoryPressure,
        memoryUsedBytes: payload.snapshot.memoryUsedBytes,
        swapUsedBytes: payload.snapshot.swapUsedBytes,
        loadOneMinute: payload.snapshot.loadAverage.oneMinute,
        worstSeverity: worst
    )
}

// MARK: - Main

let args = CommandLine.arguments
guard let opts = parseArgs(args) else {
    printUsage()
    exit(2)
}

guard validate(interval: opts.intervalSeconds) else {
    log("Interval \(opts.intervalSeconds) out of range [\(minimumIntervalSeconds), \(maximumIntervalSeconds)]")
    exit(2)
}

guard opts.once || validate(outputPath: opts.outputPath) else {
    log("Refusing to write outside \(allowedOutputPrefix): \(opts.outputPath)")
    exit(2)
}

let processSampler = ProcessSampler()
let rules = RulesEngine()

func takeSnapshot() -> SnapshotPayload {
    let system = SystemSampler.sample()
    let processes = processSampler.sample()
    let diagnoses = rules.evaluate(snapshot: system, processes: processes)
    return SnapshotPayload(
        capturedAt: Date(),
        snapshot: system,
        processes: processes,
        diagnoses: diagnoses
    )
}

if opts.once {
    // Prime then sample so per-process CPU deltas are real, not zeros.
    _ = takeSnapshot()
    Thread.sleep(forTimeInterval: max(opts.intervalSeconds, minimumIntervalSeconds))
    let payload = takeSnapshot()
    let data = try jsonEncoder.encode(payload)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(0)
}

log("whirr-sampler starting (interval=\(opts.intervalSeconds)s, output=\(opts.outputPath))")
log("Running as uid=\(getuid()) euid=\(geteuid())")

// Prime the per-process sampler so the first emitted snapshot has real
// CPU% values rather than all zeros.
_ = takeSnapshot()

// Recover any history the daemon previously wrote — gives the menu bar
// a populated timeline immediately after the daemon (or whole machine)
// has been restarted, instead of needing 30 minutes to fill back up.
var historyPoints = loadHistoryOrEmpty(from: defaultHistoryPath)
log("Loaded \(historyPoints.count) history points from prior run")

// Signal handling: log and exit cleanly. launchd will restart us per the
// plist's KeepAlive policy, but a clean exit means our log line lands first.
signal(SIGTERM) { _ in
    FileHandle.standardError.write(Data("whirr-sampler received SIGTERM, exiting\n".utf8))
    exit(0)
}
signal(SIGINT) { _ in
    FileHandle.standardError.write(Data("whirr-sampler received SIGINT, exiting\n".utf8))
    exit(0)
}

while true {
    Thread.sleep(forTimeInterval: opts.intervalSeconds)
    let payload = takeSnapshot()

    historyPoints.append(trendPoint(from: payload))
    if historyPoints.count > historyMaxPoints {
        historyPoints.removeFirst(historyPoints.count - historyMaxPoints)
    }

    do {
        try write(payload, to: opts.outputPath)
        try write(TrendHistory(points: historyPoints), to: defaultHistoryPath)
    } catch {
        log("Write failed: \(error)")
        // Don't exit — transient errors (disk full, perm flap) shouldn't
        // tear down the daemon. launchd would restart us anyway, but the
        // back-off would lose history.
    }
}
