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
        let name: String
    }

    private var previous: [Int32: Timing] = [:]
    private var previousSampleTime: TimeInterval = 0
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
                if let prior = previous[pid] {
                    let delta = timing.totalCPUNanoseconds >= prior.totalCPUNanoseconds
                        ? timing.totalCPUNanoseconds - prior.totalCPUNanoseconds
                        : 0
                    cpuPercent = (Double(delta) / elapsedNs) * 100.0
                } else {
                    cpuPercent = 0
                }
                samples.append(ProcessSample(
                    pid: pid,
                    name: timing.name,
                    cpuPercent: cpuPercent,
                    memoryBytes: timing.residentBytes
                ))
            }
        }

        previous = current
        previousSampleTime = now

        return samples.sorted { $0.cpuPercent > $1.cpuPercent }
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
        return Timing(
            totalCPUNanoseconds: cpuNanoseconds,
            residentBytes: info.ri_resident_size,
            name: processName(pid: pid)
        )
    }

    private func processName(pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let written = proc_name(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return "pid \(pid)" }
        return String(cString: buffer)
    }
}
