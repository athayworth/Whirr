import XCTest
@testable import WhirrCore

final class ProcessSafetyTests: XCTestCase {
    private func proc(name: String, path: String? = nil) -> ProcessSample {
        ProcessSample(
            pid: 1, name: name, cpuPercent: 0, memoryBytes: 0,
            executablePath: path
        )
    }

    func testKernelTaskIsSystemCritical() {
        XCTAssertEqual(
            ProcessClassifier.classify(proc(name: "kernel_task", path: "/System/kernel")),
            .systemCritical
        )
    }

    func testLaunchdIsSystemCritical() {
        XCTAssertEqual(
            ProcessClassifier.classify(proc(name: "launchd", path: "/sbin/launchd")),
            .systemCritical
        )
    }

    func testFinderIsSystemCritical() {
        // Finder lives under /System/Library/CoreServices on modern macOS.
        XCTAssertEqual(
            ProcessClassifier.classify(proc(name: "Finder",
                path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")),
            .systemCritical
        )
    }

    func testApplicationsPathIsUserApp() {
        XCTAssertEqual(
            ProcessClassifier.classify(proc(name: "Arc",
                path: "/Applications/Arc.app/Contents/MacOS/Arc")),
            .userApp
        )
    }

    func testHelperPatternWinsOverApplicationPath() {
        // Arc's renderer helpers live under /Applications/Arc.app/...
        // but they should classify as helper, not userApp — killing them
        // directly is the wrong move.
        XCTAssertEqual(
            ProcessClassifier.classify(proc(name: "Arc Helper (Renderer)",
                path: "/Applications/Arc.app/Contents/Frameworks/ArcCore.framework/Helpers/Arc Helper (Renderer)")),
            .helper
        )
    }

    func testNodeIsDevTool() {
        XCTAssertEqual(
            ProcessClassifier.classify(proc(name: "node",
                path: "/Users/alex/.nvm/versions/node/v20.0.0/bin/node")),
            .devTool
        )
    }

    func testPythonIsDevTool() {
        XCTAssertEqual(
            ProcessClassifier.classify(proc(name: "python3", path: nil)),
            .devTool
        )
    }

    func testSystemLibraryIsSystemService() {
        XCTAssertEqual(
            ProcessClassifier.classify(proc(name: "mds_stores",
                path: "/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Support/mds_stores")),
            .systemService
        )
    }

    func testUsrLibexecIsSystemService() {
        XCTAssertEqual(
            ProcessClassifier.classify(proc(name: "cfprefsd",
                path: "/usr/libexec/cfprefsd")),
            .systemService
        )
    }

    func testUnknownWhenNoPathAndNotInList() {
        XCTAssertEqual(
            ProcessClassifier.classify(proc(name: "some-random-binary", path: nil)),
            .unknown
        )
    }
}
