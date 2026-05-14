import Foundation
import Darwin

public enum SystemSampler {
    public static func sample() -> SystemSnapshot {
        let vm = vmStatistics()
        let pageSize = UInt64(vm_kernel_page_size)

        let activeBytes = UInt64(vm.active_count) * pageSize
        let wiredBytes = UInt64(vm.wire_count) * pageSize
        let compressedBytes = UInt64(vm.compressor_page_count) * pageSize
        let freeBytes = UInt64(vm.free_count) * pageSize
        let inactiveBytes = UInt64(vm.inactive_count) * pageSize
        let speculativeBytes = UInt64(vm.speculative_count) * pageSize

        let usedBytes = activeBytes + wiredBytes + compressedBytes
        let availableBytes = freeBytes + inactiveBytes + speculativeBytes

        return SystemSnapshot(
            memoryUsedBytes: usedBytes,
            memoryFreeBytes: availableBytes,
            memoryPressure: classifyPressure(vm: vm),
            swapUsedBytes: swapUsedBytes(),
            thermalState: ThermalState(ProcessInfo.processInfo.thermalState),
            loadAverage: currentLoadAverage()
        )
    }

    private static func vmStatistics() -> vm_statistics64_data_t {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        _ = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
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

    private static func classifyPressure(vm: vm_statistics64_data_t) -> MemoryPressure {
        let resident = UInt64(vm.free_count)
            + UInt64(vm.active_count)
            + UInt64(vm.inactive_count)
            + UInt64(vm.wire_count)
            + UInt64(vm.compressor_page_count)
            + UInt64(vm.speculative_count)
        guard resident > 0 else { return .normal }

        let freeRatio = Double(UInt64(vm.free_count) + UInt64(vm.speculative_count)) / Double(resident)
        let compressedRatio = Double(vm.compressor_page_count) / Double(resident)

        if freeRatio < 0.05 || compressedRatio > 0.30 { return .critical }
        if freeRatio < 0.10 || compressedRatio > 0.15 { return .warning }
        return .normal
    }
}
