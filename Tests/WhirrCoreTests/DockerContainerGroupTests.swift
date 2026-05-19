import XCTest
@testable import WhirrCore

final class DockerContainerGroupTests: XCTestCase {
    private static let mb: UInt64 = 1_048_576
    private static let gb: UInt64 = 1_073_741_824
    private var mb: UInt64 { Self.mb }
    private var gb: UInt64 { Self.gb }

    private func container(
        name: String,
        mem: UInt64,
        project: String? = nil,
        service: String? = nil
    ) -> DockerContainer {
        DockerContainer(
            id: name, name: name,
            image: "test", cpuPercent: 0,
            memoryBytes: mem, memoryLimitBytes: nil,
            composeProject: project, composeService: service, status: nil
        )
    }

    func testGroupsByComposeProject() {
        let groups = DockerContainerGroup.group([
            container(name: "db", mem: 1 * gb, project: "alpha"),
            container(name: "web", mem: 500 * mb, project: "alpha"),
            container(name: "redis", mem: 100 * mb, project: "beta")
        ])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].project, "alpha")
        XCTAssertEqual(groups[0].members.count, 2)
        XCTAssertEqual(groups[1].project, "beta")
    }

    func testGroupsSortedByTotalMemoryDescending() {
        let groups = DockerContainerGroup.group([
            container(name: "small", mem: 100 * mb, project: "small-project"),
            container(name: "big", mem: 2 * gb, project: "big-project")
        ])
        XCTAssertEqual(groups[0].project, "big-project")
        XCTAssertEqual(groups[1].project, "small-project")
    }

    func testMembersWithinGroupSortedByMemoryDescending() {
        let groups = DockerContainerGroup.group([
            container(name: "small", mem: 100 * mb, project: "p"),
            container(name: "big", mem: 2 * gb, project: "p"),
            container(name: "medium", mem: 500 * mb, project: "p")
        ])
        let names = groups[0].members.map(\.name)
        XCTAssertEqual(names, ["big", "medium", "small"])
    }

    func testUngroupedContainersAlwaysLast() {
        // Ungrouped container has 5 GB — larger than any project. Still goes last.
        let groups = DockerContainerGroup.group([
            container(name: "huge-orphan", mem: 5 * gb, project: nil),
            container(name: "tiny-project-member", mem: 100 * mb, project: "p")
        ])
        XCTAssertEqual(groups[0].project, "p")
        XCTAssertNil(groups[1].project)
    }

    func testTotalsComputedCorrectly() {
        let groups = DockerContainerGroup.group([
            container(name: "a", mem: 1 * gb, project: "x"),
            container(name: "b", mem: 500 * mb, project: "x")
        ])
        XCTAssertEqual(groups[0].totalMemoryBytes, 1 * gb + 500 * mb)
    }
}
