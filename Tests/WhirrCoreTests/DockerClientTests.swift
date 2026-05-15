import XCTest
@testable import WhirrCore

final class DockerClientTests: XCTestCase {
    // MARK: - HTTP body parsing

    func testParseHTTPBodyExtractsJSONAfterHeaders() throws {
        let raw = Data(
            ("HTTP/1.0 200 OK\r\n" +
             "Content-Type: application/json\r\n" +
             "\r\n" +
             "{\"hello\":\"world\"}").utf8
        )
        let body = try DockerClient.parseHTTPBody(raw)
        XCTAssertEqual(String(data: body, encoding: .utf8), "{\"hello\":\"world\"}")
    }

    func testParseHTTPBodyRejectsNon200() {
        let raw = Data(
            ("HTTP/1.0 404 Not Found\r\n" +
             "\r\n" +
             "nope").utf8
        )
        XCTAssertThrowsError(try DockerClient.parseHTTPBody(raw)) { error in
            guard case DockerClient.ClientError.nonOKStatus = error else {
                XCTFail("Expected nonOKStatus, got \(error)")
                return
            }
        }
    }

    func testParseHTTPBodyRejectsMissingSeparator() {
        let raw = Data("HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nNo body separator".utf8)
        XCTAssertThrowsError(try DockerClient.parseHTTPBody(raw))
    }

    // MARK: - CPU percent computation

    private func stats(
        cpu: UInt64, prevCpu: UInt64,
        system: UInt64, prevSystem: UInt64,
        onlineCpus: Int? = nil,
        percpuCount: Int? = nil
    ) -> DockerClient.RawStats {
        DockerClient.RawStats(
            cpu_stats: .init(
                cpu_usage: .init(
                    total_usage: cpu,
                    percpu_usage: percpuCount.map { Array(repeating: UInt64(0), count: $0) }
                ),
                system_cpu_usage: system,
                online_cpus: onlineCpus
            ),
            precpu_stats: .init(
                cpu_usage: .init(total_usage: prevCpu, percpu_usage: nil),
                system_cpu_usage: prevSystem,
                online_cpus: nil
            ),
            memory_stats: .init(usage: 0, limit: 0)
        )
    }

    func testCPUPercentMatchesDockerStatsFormula() {
        // A container using 100% of one core: cpuDelta == systemDelta / onlineCpus.
        // With onlineCpus = 8, that's a 1/8 ratio. Expected output: 100%.
        let s = stats(cpu: 100, prevCpu: 0, system: 800, prevSystem: 0, onlineCpus: 8)
        let pct = DockerClient.computeCPUPercent(stats: s)
        XCTAssertEqual(pct, 100.0, accuracy: 0.001)
    }

    func testCPUPercentScalesAboveOneHundredForMultipleCores() {
        // 2-core container fully busy on an 8-core host: 200%.
        let s = stats(cpu: 200, prevCpu: 0, system: 800, prevSystem: 0, onlineCpus: 8)
        let pct = DockerClient.computeCPUPercent(stats: s)
        XCTAssertEqual(pct, 200.0, accuracy: 0.001)
    }

    func testCPUPercentZeroWhenSystemDeltaIsZero() {
        // First-sample case: precpu_stats hasn't been populated yet.
        let s = stats(cpu: 100, prevCpu: 0, system: 0, prevSystem: 0, onlineCpus: 8)
        XCTAssertEqual(DockerClient.computeCPUPercent(stats: s), 0)
    }

    func testCPUPercentFallsBackToPercpuCountWhenOnlineCpusMissing() {
        // Older Docker versions may not include online_cpus — use percpu_usage length.
        let s = stats(cpu: 100, prevCpu: 0, system: 400, prevSystem: 0, onlineCpus: nil, percpuCount: 4)
        let pct = DockerClient.computeCPUPercent(stats: s)
        XCTAssertEqual(pct, 100.0, accuracy: 0.001)
    }
}
