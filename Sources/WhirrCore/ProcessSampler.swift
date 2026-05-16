import Foundation
import Darwin

/// Samples per-process CPU/memory using libproc.
/// CPU% is computed by diffing cumulative CPU time across two samples, so the first
/// call after construction returns an empty list — call again after a short interval
/// for usable data.
///
/// **Apple Silicon timebase note:** `proc_pid_rusage`'s `ri_user_time` /
/// `ri_system_time` are documented as nanoseconds, but on M-series Macs the kernel
/// actually stores them in raw `mach_absolute_time` ticks (the conversion path
/// inside the kernel divides ticks by 1000 expecting nanoseconds, but the ticks
/// are on a ~24 MHz timebase, so reported values are ~41× too low). We correct
/// using `mach_timebase_info` to recover real nanoseconds. On Intel Macs the
/// ratio is 1/1, so the correction is a no-op.
public final class ProcessSampler {
    public init() {}

    private struct Timing {
        let totalCPUNanoseconds: UInt64
        let residentBytes: UInt64
        let diskBytesRead: UInt64
        let diskBytesWritten: UInt64
        let name: String
    }

    /// Identity info that doesn't change over a process's lifetime — path,
    /// uid, ppid. Cached per pid so we don't re-read it every sample.
    private struct Identity {
        let executablePath: String?
        let userId: UInt32?
        let parentPid: Int32?
    }

    /// A "high CPU sample" is one above this percentage. Single-core
    /// pegging registers as 100% on macOS, so this catches the runaway-
    /// dev-script case without flagging multi-threaded steady-state work
    /// (browsers/editors typically don't sustain individual processes
    /// above this on a healthy machine).
    private static let highCpuThresholdPercent: Double = 60.0
    /// Below this, we consider the process effectively idle. 1% is low
    /// enough that background-housekeeping ticks (signal handlers, OS
    /// callbacks) don't reset the counter on every sample.
    private static let idleCpuThresholdPercent: Double = 1.0

    private var previous: [Int32: Timing] = [:]
    private var previousSampleTime: TimeInterval = 0
    /// Per-pid counter of consecutive high-CPU samples. Grows unbounded
    /// while the streak holds, resets to 0 the moment CPU drops below the
    /// threshold. Simpler and longer-lived than the previous ring-buffer
    /// approach.
    private var sustainedHighCounts: [Int32: Int] = [:]
    private var sustainedIdleCounts: [Int32: Int] = [:]
    /// Per-pid rolling memory history. We only need the oldest entry within
    /// the window, but keeping a small ring buffer is simpler than tracking
    /// just one timestamped baseline; at ~200 samples × 8 bytes × 1000 pids
    /// the overhead is ~1.6 MB which is fine for the menu bar app.
    private var memoryHistory: [Int32: [UInt64]] = [:]
    /// 200 samples × 3 s = 10 minutes of memory history per process.
    private static let memoryHistoryCapacity = 200
    /// Cached command lines. We use `[Int32: String?]` so a failed read
    /// (e.g. other-user process when we're not root) is remembered as
    /// nil rather than retried every sample — that would otherwise burn
    /// hundreds of sysctl calls per tick for no benefit.
    private var commandLineCache: [Int32: String?] = [:]
    /// Cached executable path / uid / ppid. Same caching pattern — these
    /// don't change over a pid's lifetime, so one read per pid suffices.
    private var identityCache: [Int32: Identity] = [:]
    private let timebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (info.numer, info.denom)
    }()

    /// Returns process samples sorted by CPU% descending.
    public func sample() -> [ProcessSample] {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsedSeconds = previousSampleTime == 0 ? 0 : (now - previousSampleTime)
        let current = currentTimings()

        var samples: [ProcessSample] = []
        if elapsedSeconds > 0 {
            samples.reserveCapacity(current.count)
            let elapsedNs = elapsedSeconds * 1_000_000_000
            for (pid, timing) in current {
                let cpuPercent: Double
                let diskReadPerSec: UInt64
                let diskWritePerSec: UInt64
                if let prior = previous[pid] {
                    let delta = timing.totalCPUNanoseconds >= prior.totalCPUNanoseconds
                        ? timing.totalCPUNanoseconds - prior.totalCPUNanoseconds
                        : 0
                    cpuPercent = (Double(delta) / elapsedNs) * 100.0
                    diskReadPerSec = perSecond(
                        current: timing.diskBytesRead,
                        prior: prior.diskBytesRead,
                        elapsedSeconds: elapsedSeconds
                    )
                    diskWritePerSec = perSecond(
                        current: timing.diskBytesWritten,
                        prior: prior.diskBytesWritten,
                        elapsedSeconds: elapsedSeconds
                    )
                } else {
                    cpuPercent = 0
                    diskReadPerSec = 0
                    diskWritePerSec = 0
                }

                updateSustainedCounters(pid: pid, cpuPercent: cpuPercent)
                let memoryDelta = recordAndComputeMemoryDelta(pid: pid, currentBytes: timing.residentBytes)
                let identity = identity(forPID: pid)

                samples.append(ProcessSample(
                    pid: pid,
                    name: timing.name,
                    cpuPercent: cpuPercent,
                    memoryBytes: timing.residentBytes,
                    diskReadBytesPerSec: diskReadPerSec,
                    diskWriteBytesPerSec: diskWritePerSec,
                    commandLine: commandLine(forPID: pid),
                    sustainedHighCpuSamples: sustainedHighCounts[pid] ?? 0,
                    sustainedIdleSamples: sustainedIdleCounts[pid] ?? 0,
                    memoryDelta10MinBytes: memoryDelta,
                    executablePath: identity.executablePath,
                    userId: identity.userId,
                    parentPid: identity.parentPid
                ))
            }
        }

        previous = current
        previousSampleTime = now

        // Prune state for pids that disappeared since the last sample.
        let currentPidSet = Set(current.keys)
        sustainedHighCounts = sustainedHighCounts.filter { currentPidSet.contains($0.key) }
        sustainedIdleCounts = sustainedIdleCounts.filter { currentPidSet.contains($0.key) }
        memoryHistory = memoryHistory.filter { currentPidSet.contains($0.key) }
        commandLineCache = commandLineCache.filter { currentPidSet.contains($0.key) }
        identityCache = identityCache.filter { currentPidSet.contains($0.key) }

        return samples.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    private func identity(forPID pid: Int32) -> Identity {
        if let cached = identityCache[pid] { return cached }
        let path = readExecutablePath(pid: pid)
        let (uid, ppid) = readBsdShortInfo(pid: pid)
        let id = Identity(executablePath: path, userId: uid, parentPid: ppid)
        identityCache[pid] = id
        return id
    }

    private func readExecutablePath(pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is 4*MAXPATHLEN = 4096.
        var buffer = [CChar](repeating: 0, count: 4096)
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        return String(cString: buffer)
    }

    private func readBsdShortInfo(pid: Int32) -> (uid: UInt32?, ppid: Int32?) {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        let written = withUnsafeMutablePointer(to: &info) { ptr in
            proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, ptr, size)
        }
        guard written == size else { return (nil, nil) }
        return (UInt32(info.pbsi_uid), Int32(info.pbsi_ppid))
    }

    private func recordAndComputeMemoryDelta(pid: Int32, currentBytes: UInt64) -> Int64? {
        var history = memoryHistory[pid, default: []]
        history.append(currentBytes)
        if history.count > Self.memoryHistoryCapacity {
            history.removeFirst(history.count - Self.memoryHistoryCapacity)
        }
        memoryHistory[pid] = history
        // Only return a delta once we have a full 10-minute window. Earlier
        // values would conflate "process just started" with "no growth."
        guard history.count == Self.memoryHistoryCapacity, let oldest = history.first else {
            return nil
        }
        return Int64(currentBytes) - Int64(oldest)
    }

    private func updateSustainedCounters(pid: Int32, cpuPercent: Double) {
        if cpuPercent >= Self.highCpuThresholdPercent {
            sustainedHighCounts[pid, default: 0] += 1
        } else {
            sustainedHighCounts[pid] = 0
        }
        if cpuPercent < Self.idleCpuThresholdPercent {
            sustainedIdleCounts[pid, default: 0] += 1
        } else {
            sustainedIdleCounts[pid] = 0
        }
    }

    private func currentTimings() -> [Int32: Timing] {
        let pids = listPIDs()
        var result: [Int32: Timing] = [:]
        result.reserveCapacity(pids.count)
        for pid in pids where pid > 0 {
            guard let timing = timing(forPID: pid) else { continue }
            result[pid] = timing
        }
        return result
    }

    private func listPIDs() -> [Int32] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        let capacity = Int(needed) / MemoryLayout<Int32>.size
        var pids = [Int32](repeating: 0, count: capacity)
        let filled = pids.withUnsafeMutableBufferPointer { buffer -> Int32 in
            let byteCount = Int32(buffer.count * MemoryLayout<Int32>.size)
            return proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, byteCount)
        }
        guard filled > 0 else { return [] }
        let count = Int(filled) / MemoryLayout<Int32>.size
        return Array(pids.prefix(count))
    }

    private func timing(forPID pid: Int32) -> Timing? {
        // proc_pid_rusage(RUSAGE_INFO_V4) is what `top` and Activity Monitor use.
        // ri_user_time + ri_system_time give cumulative CPU time across both
        // live and terminated threads, in nanoseconds — *unlike* proc_pidinfo's
        // pti_total_user, which on modern macOS appears not to fully account
        // for live thread time and reads ~40× low for long-running processes.
        //
        // The Swift import for `proc_pid_rusage`'s buffer parameter is awkward:
        // `rusage_info_t` is `typedef void * rusage_info_t`, so the buffer arg
        // imports as `UnsafeMutablePointer<rusage_info_t?>` (pointer to optional
        // raw pointer). The kernel ignores the C type entirely and writes the
        // struct through the address it's given, so we rebind our struct
        // pointer to that type to satisfy the compiler.
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { infoPtr -> Int32 in
            UnsafeMutableRawPointer(infoPtr).withMemoryRebound(
                to: rusage_info_t?.self,
                capacity: 1
            ) { typedPtr in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, typedPtr)
            }
        }
        guard rc == 0 else { return nil }

        let rawCPUTicks = info.ri_user_time &+ info.ri_system_time
        let cpuNanoseconds = rawCPUTicks &* UInt64(timebase.numer) / UInt64(timebase.denom)
        // `ri_phys_footprint` is what Activity Monitor's "Memory" column shows:
        // resident pages plus pages held in the page compressor. It's a much
        // better proxy for "how much memory is this process responsible for"
        // than `ri_resident_size`, which excludes compressed pages and so
        // collapses to small values exactly when memory pressure is high.
        return Timing(
            totalCPUNanoseconds: cpuNanoseconds,
            residentBytes: info.ri_phys_footprint,
            diskBytesRead: info.ri_diskio_bytesread,
            diskBytesWritten: info.ri_diskio_byteswritten,
            name: processName(pid: pid)
        )
    }

    private func perSecond(current: UInt64, prior: UInt64, elapsedSeconds: TimeInterval) -> UInt64 {
        guard current >= prior, elapsedSeconds > 0 else { return 0 }
        let delta = current - prior
        return UInt64(Double(delta) / elapsedSeconds)
    }

    private func processName(pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let written = proc_name(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return "pid \(pid)" }
        return String(cString: buffer)
    }

    /// Maximum joined-command-line length we expose. Long argvs (Electron
    /// apps, browser renderers) blow this out; we keep things readable in
    /// the UI and bounded in the wire format.
    private static let commandLineCharLimit = 256

    private func commandLine(forPID pid: Int32) -> String? {
        if let cached = commandLineCache[pid] {
            return cached
        }
        let value = readCommandLine(pid: pid)
        commandLineCache[pid] = value
        return value
    }

    /// Read the full argv for `pid` via the `KERN_PROCARGS2` sysctl. The
    /// buffer layout is:
    ///   [argc: Int32][exec_path: cstr][padding: \0…][argv[0..argc-1]: cstr…][envp: cstr…]
    /// We pull argv only — exec_path is redundant with argv[0] for our
    /// purposes, and envp can be huge / contain secrets.
    private func readCommandLine(pid: Int32) -> String? {
        // First, ask the kernel how big argv areas can be.
        var argMaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argMax: Int32 = 0
        var argMaxSize = MemoryLayout<Int32>.size
        guard sysctl(&argMaxMib, 2, &argMax, &argMaxSize, nil, 0) == 0, argMax > 0 else {
            return nil
        }

        var procArgsMib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var actualSize = Int(argMax)
        var buffer = Data(count: actualSize)
        let rc = buffer.withUnsafeMutableBytes { rawBuf -> Int32 in
            guard let base = rawBuf.baseAddress else { return -1 }
            return sysctl(&procArgsMib, 3, base, &actualSize, nil, 0)
        }
        // Common failure modes (other-user process when not root, kernel
        // tasks, very short-lived process) all surface as a non-zero return.
        guard rc == 0, actualSize > MemoryLayout<Int32>.size else { return nil }

        return buffer.withUnsafeBytes { rawBuf -> String? in
            guard rawBuf.count >= actualSize else { return nil }
            let argc = rawBuf.load(as: Int32.self)
            guard argc > 0 else { return nil }

            var offset = MemoryLayout<Int32>.size
            // Skip the executable path (null-terminated).
            while offset < actualSize && rawBuf[offset] != 0 { offset += 1 }
            // Skip the run of zero bytes between exec_path and argv[0].
            while offset < actualSize && rawBuf[offset] == 0 { offset += 1 }

            var args: [String] = []
            args.reserveCapacity(Int(argc))
            for _ in 0..<argc {
                guard offset < actualSize else { break }
                let start = offset
                while offset < actualSize && rawBuf[offset] != 0 { offset += 1 }
                let bytes = rawBuf[start..<offset]
                if let s = String(bytes: bytes, encoding: .utf8), !s.isEmpty {
                    args.append(s)
                }
                if offset < actualSize { offset += 1 }
            }

            guard !args.isEmpty else { return nil }
            let joined = args.joined(separator: " ")
            if joined.count > Self.commandLineCharLimit {
                return String(joined.prefix(Self.commandLineCharLimit)) + "…"
            }
            return joined
        }
    }
}
