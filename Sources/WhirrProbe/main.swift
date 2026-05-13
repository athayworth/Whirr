import Foundation
import Darwin
import WhirrCore

func formatBytes(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB, .useMB]
    formatter.countStyle = .memory
    return formatter.string(fromByteCount: Int64(bytes))
}

/// Optional diagnostic: pass a PID as the first argument and the probe will
/// print raw CPU-time field values from both proc_pid_rusage and proc_pidinfo
/// across a 2s window, so the math can be cross-checked against `top`.
func diagnoseCPUAPIs(forPID pid: Int32) {
    func readRusage() -> rusage_info_v4? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { infoPtr -> Int32 in
            UnsafeMutableRawPointer(infoPtr).withMemoryRebound(
                to: rusage_info_t?.self,
                capacity: 1
            ) { typedPtr in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, typedPtr)
            }
        }
        guard rc == 0 else { print("  proc_pid_rusage rc=\(rc) errno=\(errno)"); return nil }
        return info
    }
    func readTaskinfo() -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let n = withUnsafeMutablePointer(to: &info) { ptr in
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, ptr, size)
        }
        guard n == size else { print("  proc_pidinfo bytes=\(n)"); return nil }
        return info
    }

    print("--- CPU API diagnostic for pid \(pid) ---")
    guard let r1 = readRusage(), let t1 = readTaskinfo() else { return }
    let w1 = ProcessInfo.processInfo.systemUptime
    Thread.sleep(forTimeInterval: 2.0)
    guard let r2 = readRusage(), let t2 = readTaskinfo() else { return }
    let w2 = ProcessInfo.processInfo.systemUptime

    let elapsedNs = (w2 - w1) * 1e9
    let rusageDelta = (r2.ri_user_time &- r1.ri_user_time) &+ (r2.ri_system_time &- r1.ri_system_time)
    let pidinfoDelta = (t2.pti_total_user &- t1.pti_total_user) &+ (t2.pti_total_system &- t1.pti_total_system)

    // Apply mach timebase conversion — the kernel reports CPU times in raw ticks
    // on Apple Silicon, not nanoseconds as documented.
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    let scale = Double(tb.numer) / Double(tb.denom)
    print(String(format: "  wall elapsed:    %.3fs", w2 - w1))
    print(String(format: "  mach timebase:   %u/%u (ratio %.2f)", tb.numer, tb.denom, scale))
    print(String(format: "  proc_pid_rusage: Δ raw = %d → %.2f%% per core (corrected for timebase)", rusageDelta, Double(rusageDelta) * scale / elapsedNs * 100))
    print(String(format: "  proc_pidinfo:    Δ raw = %d → %.2f%% per core (corrected for timebase)", pidinfoDelta, Double(pidinfoDelta) * scale / elapsedNs * 100))
}

print("Whirr Probe")
print("--------------------------------------------------")

let snapshot = SystemSampler.sample()
print("\n[1/3] System sampler")
print("  Memory used:     \(formatBytes(snapshot.memoryUsedBytes))")
print("  Memory free:     \(formatBytes(snapshot.memoryFreeBytes))")
print("  Memory pressure: \(snapshot.memoryPressure)")
print("  Swap used:       \(formatBytes(snapshot.swapUsedBytes))")
print("  Thermal state:   \(snapshot.thermalState)")
let (l1, l5, l15) = snapshot.loadAverage
print("  Load avg:        \(String(format: "%.2f, %.2f, %.2f", l1, l5, l15))")

if CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) {
    print("\n[2/3] CPU API diagnostic")
    diagnoseCPUAPIs(forPID: pid)
}

print("\n[\(CommandLine.arguments.count > 1 ? "3/3" : "2/2")] Process sampler (2s window)")
let processSampler = ProcessSampler()
_ = processSampler.sample()
Thread.sleep(forTimeInterval: 2.0)
let processes = processSampler.sample()
print("  Total processes observed: \(processes.count)")

func formatRate(_ bytesPerSec: UInt64) -> String {
    let mb = Double(bytesPerSec) / 1_048_576
    return String(format: "%6.1f MB/s", mb)
}

print("  Top 8 by CPU%:")
for proc in processes.prefix(8) {
    let cpuStr = String(format: "%6.1f%%", proc.cpuPercent)
    let memStr = formatBytes(proc.memoryBytes).padding(toLength: 9, withPad: " ", startingAt: 0)
    let ioStr = formatRate(proc.diskIOBytesPerSec)
    print("    \(cpuStr)  \(memStr)  io=\(ioStr)  pid=\(proc.pid)  \(proc.name)")
}

let topByIO = processes.sorted { $0.diskIOBytesPerSec > $1.diskIOBytesPerSec }
if let busiest = topByIO.first, busiest.diskIOBytesPerSec > 0 {
    print("  Top 5 by disk I/O:")
    for proc in topByIO.prefix(5) where proc.diskIOBytesPerSec > 0 {
        let readStr = formatRate(proc.diskReadBytesPerSec)
        let writeStr = formatRate(proc.diskWriteBytesPerSec)
        print("    r=\(readStr)  w=\(writeStr)  pid=\(proc.pid)  \(proc.name)")
    }
}

let diagnoses = RulesEngine().evaluate(snapshot: snapshot, processes: processes)
print("\n  \(diagnoses.count) diagnoses raised by rules engine.")
print("\nDone.")
