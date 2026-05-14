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

    /// Per-process CPU history is a small ring buffer of recent CPU%.
    /// We keep just enough samples to recognize sustained high load — at
    /// 3s sampling cadence, 20 samples covers a minute of history.
    private static let maxHistorySamples = 20
    /// A "high CPU sample" is one above this percentage. Single-core
    /// pegging registers as 100% on macOS, so this catches the runaway-
    /// dev-script case without flagging multi-threaded steady-state work
    /// (browsers/editors typically don't sustain individual processes
    /// above this on a healthy machine).
    private static let highCpuThresholdPercent: Double = 60.0

    private var previous: [Int32: Timing] = [:]
    private var previousSampleTime: TimeInterval = 0
    private var cpuHistory: [Int32: [Double]] = [:]
    /// Cached command lines. We use `[Int32: String?]` so a failed read
    /// (e.g. other-user process when we're not root) is remembered as
    /// nil rather than retried every sample — that would otherwise burn
    /// hundreds of sysctl calls per tick for no benefit.
    private var commandLineCache: [Int32: String?] = [:]
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

                updateCpuHistory(pid: pid, cpuPercent: cpuPercent)
                let sustained = sustainedHighSamples(pid: pid)

                samples.append(ProcessSample(
                    pid: pid,
                    name: timing.name,
                    cpuPercent: cpuPercent,
                    memoryBytes: timing.residentBytes,
                    diskReadBytesPerSec: diskReadPerSec,
                    diskWriteBytesPerSec: diskWritePerSec,
                    commandLine: commandLine(forPID: pid),
                    sustainedHighCpuSamples: sustained
                ))
            }
        }

        previous = current
        previousSampleTime = now

        // Prune state for pids that disappeared since the last sample.
        let currentPidSet = Set(current.keys)
        cpuHistory = cpuHistory.filter { currentPidSet.contains($0.key) }
        commandLineCache = commandLineCache.filter { currentPidSet.contains($0.key) }

        return samples.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    private func updateCpuHistory(pid: Int32, cpuPercent: Double) {
        var history = cpuHistory[pid, default: []]
        history.append(cpuPercent)
        if history.count > Self.maxHistorySamples {
            history.removeFirst(history.count - Self.maxHistorySamples)
        }
        cpuHistory[pid] = history
    }

    private func sustainedHighSamples(pid: Int32) -> Int {
        guard let history = cpuHistory[pid] else { return 0 }
        // Count trailing samples (most recent) that exceed the threshold.
        // A drop below the threshold resets the streak.
        var count = 0
        for value in history.reversed() {
            if value >= Self.highCpuThresholdPercent {
                count += 1
            } else {
                break
            }
        }
        return count
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
