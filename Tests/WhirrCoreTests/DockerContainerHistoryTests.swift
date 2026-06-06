import XCTest
@testable import WhirrCore

final class DockerContainerHistoryTests: XCTestCase {
    private func container(id: String, cpu: Double = 0, mem: UInt64 = 0) -> DockerContainer {
        DockerContainer(
            id: id, name: id, image: "test",
            cpuPercent: cpu, memoryBytes: mem, memoryLimitBytes: nil,
            composeProject: nil, composeService: nil, status: nil
        )
    }

    func testFirstRecordCreatesSinglePoint() {
        var tracker = DockerHistoryTracker()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        tracker.record([container(id: "a", cpu: 25)], at: now)
        XCTAssertEqual(tracker.history(for: "a")?.count, 1)
        XCTAssertEqual(tracker.history(for: "a")?.first?.cpuPercent, 25)
    }

    func testSubsequentRecordsAppendNewestLast() {
        var tracker = DockerHistoryTracker()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        tracker.record([container(id: "a", cpu: 10)], at: t0)
        tracker.record([container(id: "a", cpu: 20)], at: t0.addingTimeInterval(5))
        tracker.record([container(id: "a", cpu: 30)], at: t0.addingTimeInterval(10))
        let history = tracker.history(for: "a") ?? []
        XCTAssertEqual(history.map(\.cpuPercent), [10, 20, 30])
    }

    func testCapacityCapTrimsOldest() {
        var tracker = DockerHistoryTracker()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        // Two beyond capacity — first two should fall off.
        for i in 0..<(DockerHistoryTracker.perContainerCapacity + 2) {
            tracker.record(
                [container(id: "a", cpu: Double(i))],
                at: base.addingTimeInterval(Double(i))
            )
        }
        let history = tracker.history(for: "a") ?? []
        XCTAssertEqual(history.count, DockerHistoryTracker.perContainerCapacity)
        // The oldest retained point is i=2, newest is i=N+1.
        XCTAssertEqual(history.first?.cpuPercent, 2)
        XCTAssertEqual(history.last?.cpuPercent,
                       Double(DockerHistoryTracker.perContainerCapacity + 1))
    }

    func testStaleContainersAreEventuallyPruned() {
        var tracker = DockerHistoryTracker()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        tracker.record([container(id: "exited", cpu: 10)], at: t0)
        // Immediately after — still present (within staleAfter window).
        tracker.record([container(id: "alive", cpu: 5)], at: t0.addingTimeInterval(60))
        XCTAssertNotNil(tracker.history(for: "exited"))
        // Now well past staleAfter — exited container should be gone,
        // alive should remain.
        tracker.record(
            [container(id: "alive", cpu: 6)],
            at: t0.addingTimeInterval(DockerHistoryTracker.staleAfter + 120)
        )
        XCTAssertNil(tracker.history(for: "exited"))
        XCTAssertNotNil(tracker.history(for: "alive"))
    }

    func testReappearingContainerResumesIntoSameSeries() {
        // A container that disappears briefly within the grace window
        // and then reappears should retain its history (not start fresh).
        var tracker = DockerHistoryTracker()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        tracker.record([container(id: "flap", cpu: 1)], at: t0)
        tracker.record([container(id: "flap", cpu: 2)], at: t0.addingTimeInterval(5))
        // Skipped sample (Docker daemon hiccup).
        tracker.record([], at: t0.addingTimeInterval(10))
        // Came back.
        tracker.record([container(id: "flap", cpu: 3)], at: t0.addingTimeInterval(15))
        let history = tracker.history(for: "flap") ?? []
        XCTAssertEqual(history.map(\.cpuPercent), [1, 2, 3])
    }
}
