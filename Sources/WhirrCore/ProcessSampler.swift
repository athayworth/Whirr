import Foundation
import Darwin

/// Samples per-process CPU/memory using libproc (the same APIs `top` and Activity Monitor use).
/// CPU% is computed by diffing cumulative CPU time across two samples, so the first call
/// after construction returns an empty list — call again after a short interval for usable data.
public final class ProcessSampler {
    public init() {}

    private struct Timing {
        let totalCPUNanoseconds: UInt64
        let residentBytes: UInt64
        let name: String
    }

    private var previous: [Int32: Timing] = [:]
    private var previousSampleTime: TimeInterval = 0

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
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let bytesWritten = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, ptr, size)
        }
        guard bytesWritten == size else { return nil }

        return Timing(
            totalCPUNanoseconds: info.pti_total_user &+ info.pti_total_system,
            residentBytes: info.pti_resident_size,
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
