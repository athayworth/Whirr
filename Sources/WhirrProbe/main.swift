import Foundation
import WhirrCore

func formatBytes(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB, .useMB]
    formatter.countStyle = .memory
    return formatter.string(fromByteCount: Int64(bytes))
}

print("Whirr Probe — verifying system + process samplers")
print("--------------------------------------------------")

print("\n[1/2] System sampler")
let snapshot = SystemSampler.sample()
print("  Memory used:     \(formatBytes(snapshot.memoryUsedBytes))")
print("  Memory free:     \(formatBytes(snapshot.memoryFreeBytes))")
print("  Memory pressure: \(snapshot.memoryPressure)")
print("  Swap used:       \(formatBytes(snapshot.swapUsedBytes))")
print("  Thermal state:   \(snapshot.thermalState)")
let (l1, l5, l15) = snapshot.loadAverage
print("  Load avg:        \(String(format: "%.2f, %.2f, %.2f", l1, l5, l15))")

print("\n[2/2] Process sampler (sampling, then waiting 2s, then sampling again)")
let processSampler = ProcessSampler()
_ = processSampler.sample()
Thread.sleep(forTimeInterval: 2.0)
let processes = processSampler.sample()

print("  Total processes observed: \(processes.count)")
print("  Top 10 by CPU%:")
for proc in processes.prefix(10) {
    let cpuStr = String(format: "%6.1f%%", proc.cpuPercent)
    let memStr = formatBytes(proc.memoryBytes)
    print("    \(cpuStr)  \(memStr.padding(toLength: 9, withPad: " ", startingAt: 0))  pid=\(proc.pid)  \(proc.name)")
}

print("\n[3/3] Rules engine")
let engine = RulesEngine()
let diagnoses = engine.evaluate(snapshot: snapshot, processes: processes)
if diagnoses.isEmpty {
    print("  No issues detected. System looks healthy.")
} else {
    for diagnosis in diagnoses {
        let tag: String
        switch diagnosis.severity {
        case .critical: tag = "[CRITICAL]"
        case .warning:  tag = "[WARNING] "
        case .ok:       tag = "[INFO]    "
        }
        print("  \(tag) \(diagnosis.title)")
        print("              \(diagnosis.detail)")
    }
}

print("\nDone.")
