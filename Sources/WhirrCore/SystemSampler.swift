import Foundation
import Darwin

/// Samples system-wide state (memory, swap, pressure, disk, load, page-in
/// rate). Instance state exists solely to compute per-second rates: the
/// kernel exposes cumulative counters (`vm.pageins`), and rate = (delta /
/// elapsed) between samples. First call after construction returns 0 for
/// rate-shaped fields — call again after an interval for usable data.
///
/// Prior versions were an `enum` with static funcs. Rates forced state; a
/// class keeps the surface small and matches ProcessSampler's shape.
public final class SystemSampler: @unchecked Sendable {
    /// Cached host port for `host_statistics64`. `mach_host_self()`
    /// returns the same task-wide send right each call without
    /// incrementing its reference count, so caching just trims a syscall
    /// per sample — there's no port to deallocate.
    private static let hostPort: mach_port_t = mach_host_self()

    /// Triggers MemoryPressureMonitor.shared init so its dispatch source
    /// is hooked up before the first sample fires.
    private static let pressureMonitor = MemoryPressureMonitor.shared

    private let lock = NSLock()
    /// Previous cumulative page-in count from vm_statistics64 + timestamp
    /// captured at the same moment. Both needed to compute rate; keeping
    /// them together prevents a "captured wall-clock now / stale kernel
    /// counter" mismatch across a slow tick.
    private var priorPageIns: UInt64 = 0
    private var priorSampleAt: TimeInterval = 0

    public init() {}

    /// Static convenience for callers who don't need page-in rate (tests,
    /// legacy call sites). Returns a snapshot with `pageInsPerSecond = 0`
    /// which is the semantically-correct "we don't know yet" value.
    public static func sample() -> SystemSnapshot {
        // Use a throw-away instance so we go through the same code path.
        // First call always returns 0 for page-in rate — expected.
        SystemSampler().sample()
    }

    public func sample() -> SystemSnapshot {
        let vm = Self.vmStatistics()
        let pageSize = UInt64(vm_kernel_page_size)

        let activeBytes = UInt64(vm.active_count) * pageSize
        let wiredBytes = UInt64(vm.wire_count) * pageSize
        let compressedBytes = UInt64(vm.compressor_page_count) * pageSize
        let freeBytes = UInt64(vm.free_count) * pageSize
        let inactiveBytes = UInt64(vm.inactive_count) * pageSize
        let speculativeBytes = UInt64(vm.speculative_count) * pageSize

        let usedBytes = activeBytes + wiredBytes + compressedBytes
        let availableBytes = freeBytes + inactiveBytes + speculativeBytes

        let (rootFree, rootTotal) = Self.rootDiskUsage()
        let pageInsPerSec = updatePageInsRate(current: vm.pageins)

        return SystemSnapshot(
            memoryUsedBytes: usedBytes,
            memoryAvailableBytes: availableBytes,
            memoryPressure: Self.classifyPressure(vm: vm),
            swapUsedBytes: Self.swapUsedBytes(),
            thermalState: ThermalState(ProcessInfo.processInfo.thermalState),
            loadAverage: Self.currentLoadAverage(),
            rootDiskFreeBytes: rootFree,
            rootDiskTotalBytes: rootTotal,
            pageInsPerSecond: pageInsPerSec
        )
    }

    private func updatePageInsRate(current: UInt64) -> Double {
        let now = ProcessInfo.processInfo.systemUptime
        return lock.withLock {
            defer {
                priorPageIns = current
                priorSampleAt = now
            }
            guard priorSampleAt > 0 else { return 0 }
            let elapsed = now - priorSampleAt
            guard elapsed > 0 else { return 0 }
            // Kernel counter can wrap or reset on rare occasion (e.g.
            // extended sleep); treat a decrease as "no signal" rather than
            // reporting a huge negative rate cast to an unsigned wraparound.
            guard current >= priorPageIns else { return 0 }
            let delta = current - priorPageIns
            return Double(delta) / elapsed
        }
    }

    private static func rootDiskUsage() -> (free: UInt64, total: UInt64) {
        var stats = statfs()
        guard "/".withCString({ statfs($0, &stats) }) == 0 else { return (0, 0) }
        let blockSize = UInt64(stats.f_bsize)
        let free = UInt64(stats.f_bavail) &* blockSize
        let total = UInt64(stats.f_blocks) &* blockSize
        return (free, total)
    }

    private static func vmStatistics() -> vm_statistics64_data_t {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        _ = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(hostPort, HOST_VM_INFO64, rebound, &count)
            }
        }
        return stats
    }

    private static func swapUsedBytes() -> UInt64 {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else { return 0 }
        return swap.xsu_used
    }

    private static func currentLoadAverage() -> LoadAverage {
        var loads = [Double](repeating: 0, count: 3)
        let count = getloadavg(&loads, 3)
        guard count == 3 else { return .zero }
        return LoadAverage(oneMinute: loads[0], fiveMinute: loads[1], fifteenMinute: loads[2])
    }

    /// Two-source pressure classification: the kernel's dispatch-source
    /// verdict (authoritative when present) max'd with our hand-rolled
    /// ratio heuristic. Taking the *max* means whichever side sees
    /// pressure first wins — we never under-report what Activity Monitor
    /// would show.
    static func classifyPressure(vm: vm_statistics64_data_t) -> MemoryPressure {
        let handRoll = handRolledPressure(vm: vm)
        guard let kernel = pressureMonitor.current else {
            // Bootstrap window — no kernel event yet. Trust the hand-roll.
            return handRoll
        }
        return max(handRoll, kernel)
    }

    /// Hand-rolled pressure. Thresholds sit deliberately *behind* what the
    /// kernel dispatch source will typically report (softer than the
    /// pre-2026-07 values of 15%/30% compressed — those cried wolf on
    /// high-RAM machines where a healthy compressor can carry >30% of
    /// pages while pressure is `.normal`). The kernel signal covers the
    /// authoritative case; this stays honest for the bootstrap window.
    static func handRolledPressure(vm: vm_statistics64_data_t) -> MemoryPressure {
        let resident = UInt64(vm.free_count)
            + UInt64(vm.active_count)
            + UInt64(vm.inactive_count)
            + UInt64(vm.wire_count)
            + UInt64(vm.compressor_page_count)
            + UInt64(vm.speculative_count)
        guard resident > 0 else { return .normal }

        let freeRatio = Double(UInt64(vm.free_count) + UInt64(vm.speculative_count)) / Double(resident)
        let compressedRatio = Double(vm.compressor_page_count) / Double(resident)

        // Critical: essentially no reclaimable memory left, OR compressor
        // holds nearly half of RAM (compression + swap is the last stop
        // before OOM).
        if freeRatio < 0.03 || compressedRatio > 0.45 { return .critical }
        // Warning: low reclaimable memory, OR the compressor is doing
        // meaningful work. 25% compressed is still not unusual on a busy
        // machine, but combined with the kernel's own signal (which we
        // max with) it should catch real degradation without being
        // trigger-happy.
        if freeRatio < 0.08 || compressedRatio > 0.25 { return .warning }
        return .normal
    }
}
