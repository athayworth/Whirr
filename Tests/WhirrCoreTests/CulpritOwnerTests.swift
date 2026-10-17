import XCTest
@testable import WhirrCore

final class CulpritOwnerTests: XCTestCase {
    func testDockerFamily() {
        XCTAssertEqual(CulpritOwner.owner(of: "com.docker.backend", dockerRunning: true), "Docker")
        XCTAssertEqual(CulpritOwner.owner(of: "com.apple.Virtualization.Virtua", dockerRunning: true), "Docker")
        XCTAssertEqual(CulpritOwner.owner(of: "Virtualization VM (probably Docker)", dockerRunning: true), "Docker")
        XCTAssertEqual(CulpritOwner.owner(of: "com.apple.Virtualization.Virtua", dockerRunning: false),
                       "com.apple.Virtualization.Virtua")
    }

    func testBackups() {
        XCTAssertEqual(CulpritOwner.owner(of: "bztransmit", dockerRunning: false), "Backblaze")
        XCTAssertEqual(CulpritOwner.owner(of: "backupd", dockerRunning: false), "Time Machine")
    }

    func testOtherNamesAreTheirOwnOwner() {
        XCTAssertEqual(CulpritOwner.owner(of: "Google Chrome", dockerRunning: false), "Google Chrome")
    }

    func testOwnerLoadShares() {
        func p(_ pid: Int32, _ name: String, cpu: Double, gb: UInt64) -> ProcessSample {
            ProcessSample(pid: pid, name: name, cpuPercent: cpu, memoryBytes: gb * 1_073_741_824)
        }
        let load = OwnerLoad.compute(processes: [p(1, "com.docker.backend", cpu: 20, gb: 1),
                                                 p(2, "com.apple.Virtualization.Virtua", cpu: 180, gb: 8),
                                                 p(3, "Safari", cpu: 100, gb: 2)],
                                     totalRAM: 32 * 1_073_741_824, describer: { $0.name }, seesAllProcesses: true)
        XCTAssertEqual(load.cpuShare["Docker"] ?? 0, 200.0 / 300.0, accuracy: 0.001)
        XCTAssertEqual(load.memoryShare["Docker"] ?? 0, 9.0 / 32.0, accuracy: 0.001)
        XCTAssertEqual(load.memoryShare["Safari"] ?? 0, 2.0 / 32.0, accuracy: 0.001)
        XCTAssertTrue(load.dockerRunning)
    }

    func testHelpersCountTowardTheirAppViaTheDescriber() {
        let helper = ProcessSample(pid: 9, name: "Google Chrome Helper (Renderer)", cpuPercent: 50, memoryBytes: 1_073_741_824)
        let load = OwnerLoad.compute(processes: [helper], totalRAM: 8 * 1_073_741_824,
                                     describer: { _ in "Google Chrome" }, seesAllProcesses: true)
        XCTAssertEqual(load.cpuShare["Google Chrome"] ?? 0, 1, accuracy: 0.001)
    }

    func testPipelineCarriesOwnerLoad() async {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("WhirrOwner-\(UUID().uuidString)")
        let pipeline = SamplingPipeline(snapshotPath: dir.appendingPathComponent("s.json").path,
                                        historyPath: dir.appendingPathComponent("h.json").path)
        let result = await pipeline.tick()
        XCTAssertFalse(result.ownerLoad.seesAllProcesses, "in-app sampling can't see other users' processes")
    }
}
