import XCTest
@testable import WhirrCore

/// Guards Whirr's parse of Harbr's on-disk config. We intentionally
/// decode a *subset* of Harbr's schema — extra keys must not break the
/// read, and a missing/malformed file must degrade gracefully.
final class HarbrConfigReaderTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhirrHarbrTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try super.tearDownWithError()
    }

    private func write(_ contents: String) throws -> String {
        let path = tmpDir.appendingPathComponent("config.json").path
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func testAbsentFileReportsAbsent() {
        let reader = HarbrConfigReader(path: tmpDir.appendingPathComponent("missing.json").path)
        XCTAssertEqual(reader.load(), .absent)
        XCTAssertEqual(reader.projects(), [])
    }

    func testParsesRealHarbrFormat() throws {
        // Directly taken from a real user's ~/.harbr/config.json — the
        // "many extra top-level and per-project keys" case. Whirr should
        // extract just what it needs and ignore the rest.
        let path = try write(#"""
        {
          "launchAtLoginEnabled": true,
          "projects": [
            {
              "directory": "/tmp/frontend",
              "name": "Frontend",
              "port": 3000,
              "startCommand": "npm run dev"
            },
            {
              "autoRestart": false,
              "captureLogs": true,
              "directory": "/tmp/api",
              "group": "Backend",
              "name": "API",
              "port": 8080,
              "startCommand": "./run.sh"
            }
          ]
        }
        """#)
        let reader = HarbrConfigReader(path: path)
        let projects = reader.projects()
        XCTAssertEqual(projects.count, 2)
        XCTAssertEqual(projects[0].name, "Frontend")
        XCTAssertEqual(projects[0].port, 3000)
        XCTAssertNil(projects[0].group)
        XCTAssertEqual(projects[1].name, "API")
        XCTAssertEqual(projects[1].port, 8080)
        XCTAssertEqual(projects[1].group, "Backend")
    }

    func testMalformedReportsMalformed() throws {
        let path = try write("{not json")
        let reader = HarbrConfigReader(path: path)
        if case .malformed = reader.load() { /* pass */ } else {
            XCTFail("Expected .malformed on unparseable JSON")
        }
        XCTAssertEqual(reader.projects(), [])
    }

    func testDeduplicatesByPort() throws {
        // Defense in depth — Harbr itself rejects duplicate ports, but if
        // one slips through the second entry gets dropped rather than
        // silently mis-attributing processes.
        let path = try write(#"""
        {"projects": [
            {"name": "A", "port": 3000, "directory": "/", "startCommand": ""},
            {"name": "B", "port": 3000, "directory": "/", "startCommand": ""}
        ]}
        """#)
        let projects = HarbrConfigReader(path: path).projects()
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].name, "A")
    }

    func testDropsInvalidPorts() throws {
        let path = try write(#"""
        {"projects": [
            {"name": "OK", "port": 3000, "directory": "/", "startCommand": ""},
            {"name": "Bogus", "port": 0, "directory": "/", "startCommand": ""},
            {"name": "TooHigh", "port": 99999, "directory": "/", "startCommand": ""}
        ]}
        """#)
        let projects = HarbrConfigReader(path: path).projects()
        XCTAssertEqual(projects.map(\.name), ["OK"])
    }

    // MARK: - Attribution

    private func proc(_ pid: Int32, _ name: String, cmd: String) -> ProcessSample {
        ProcessSample(pid: pid, name: name, cpuPercent: 1, memoryBytes: 100 * 1_048_576, commandLine: cmd)
    }

    func testAttributesByCommandLinePortFlag() {
        let projects = [HarbrProject(name: "Frontend", port: 3000)]
        let processes = [proc(42, "node", cmd: "node next dev -p 3000")]
        let statuses = HarbrAttribution.statuses(
            projects: projects,
            processes: processes,
            portListening: { _ in false }
        )
        XCTAssertEqual(statuses.count, 1)
        XCTAssertTrue(statuses[0].isRunning)
        XCTAssertEqual(statuses[0].pid, 42)
        XCTAssertEqual(statuses[0].processName, "node")
    }

    func testAttributionRespectsWordBoundary() {
        // 30000 should not match 3000.
        let projects = [HarbrProject(name: "Frontend", port: 3000)]
        let processes = [proc(42, "python", cmd: "python -m http.server 30000")]
        let statuses = HarbrAttribution.statuses(
            projects: projects,
            processes: processes,
            portListening: { _ in false }
        )
        XCTAssertFalse(statuses[0].isRunning)
        XCTAssertNil(statuses[0].pid)
    }

    func testFallsBackToPortProbeWhenNoProcessMatch() {
        // Docker case: port is held by com.docker.backend which we can't
        // attribute cleanly, but the port IS listening.
        let projects = [HarbrProject(name: "Postgres", port: 5432)]
        let statuses = HarbrAttribution.statuses(
            projects: projects,
            processes: [],
            portListening: { $0 == 5432 }
        )
        XCTAssertTrue(statuses[0].isRunning)
        XCTAssertNil(statuses[0].pid, "Fallback probe should mark running without a pid")
    }

    func testStoppedWhenNoProcessAndNoListener() {
        let projects = [HarbrProject(name: "Nothing", port: 6666)]
        let statuses = HarbrAttribution.statuses(
            projects: projects,
            processes: [],
            portListening: { _ in false }
        )
        XCTAssertFalse(statuses[0].isRunning)
    }
}
