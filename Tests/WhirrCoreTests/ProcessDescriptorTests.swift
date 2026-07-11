import XCTest
@testable import WhirrCore

/// The descriptor turns raw process names into things a non-technical
/// user can act on. These tests pin down the three-tier fallback order
/// (known name → bundle Info.plist → raw) plus the caching behavior.
final class ProcessDescriptorTests: XCTestCase {
    private func proc(_ name: String, path: String? = nil) -> ProcessSample {
        ProcessSample(pid: 1, name: name, cpuPercent: 0, memoryBytes: 0, executablePath: path)
    }

    // MARK: - Tier 1: known-name table

    func testKnownGuiAppByExecutableName() {
        // Chrome's main process comes through with an unhelpful name;
        // the table should still map it to the friendly display name.
        let desc = ProcessDescriptor().describe(proc("Google Chrome Helper (Renderer)"))
        XCTAssertEqual(desc.friendlyName, "Google Chrome")
        XCTAssertEqual(desc.category, .browser)
        XCTAssertTrue(desc.explainer.contains("tab") || desc.explainer.contains("Tabs"),
                      "Chrome explainer should mention tabs: \(desc.explainer)")
    }

    func testKnownDevRuntimeExplainerIsActionable() {
        let desc = ProcessDescriptor().describe(proc("node"))
        XCTAssertEqual(desc.friendlyName, "Node.js")
        XCTAssertEqual(desc.category, .dev)
        XCTAssertTrue(desc.explainer.contains("safe") || desc.explainer.contains("Safe"),
                      "Dev-tool explainer should tell user it's safe to kill: \(desc.explainer)")
    }

    func testKernelTaskIsMarkedSystemAndNotKillable() {
        let desc = ProcessDescriptor().describe(proc("kernel_task"))
        XCTAssertEqual(desc.category, .system)
        // Copy should discourage the user from trying to kill it.
        XCTAssertTrue(desc.explainer.lowercased().contains("can't kill")
                      || desc.explainer.lowercased().contains("leave"),
                      "kernel_task should warn against killing: \(desc.explainer)")
    }

    // MARK: - Tier 2: bundle Info.plist

    func testAppBundlePathResolvesToParentAppName() throws {
        // Fabricate a fake .app bundle in tmp and point a fake process
        // at its inner binary. Verifies the walk-up logic + Info.plist
        // read without depending on any specific app being installed.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhirrDescTest-\(UUID().uuidString).app")
        let contents = tmp.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleDisplayName": "Fictional Editor"]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))
        let binary = macOS.appendingPathComponent("editor-binary").path

        defer { try? FileManager.default.removeItem(at: tmp) }

        let desc = ProcessDescriptor().describe(proc("editor-binary", path: binary))
        XCTAssertEqual(desc.friendlyName, "Fictional Editor")
        XCTAssertEqual(desc.category, .app,
                       "Unknown bundle names fall through to generic .app category")
    }

    func testNestedHelperResolvesToTopLevelApp() throws {
        // Simulate the Chrome-helper-inside-Chrome case, but with a
        // fictional name so the known-table doesn't shortcut past our
        // bundle-walk logic.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhirrDescTest-\(UUID().uuidString).app")
        let outerContents = tmp.appendingPathComponent("Contents")
        let helperPath = outerContents
            .appendingPathComponent("Frameworks")
            .appendingPathComponent("Helper.app")
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: helperPath, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleDisplayName": "Fictional Browser"]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: outerContents.appendingPathComponent("Info.plist"))
        let helperBinary = helperPath.appendingPathComponent("helper-renderer").path

        defer { try? FileManager.default.removeItem(at: tmp) }

        let desc = ProcessDescriptor().describe(proc("helper-renderer", path: helperBinary))
        XCTAssertEqual(desc.friendlyName, "Fictional Browser",
                       "Top-level .app bundle should win over the nested Helper.app")
    }

    // MARK: - Tier 3: raw name fallback

    func testUnknownProcessGetsRawNameWithGenericExplainer() {
        let desc = ProcessDescriptor().describe(proc("some-obscure-thing", path: nil))
        XCTAssertEqual(desc.friendlyName, "some-obscure-thing")
        // Should always land on *some* explainer — never empty.
        XCTAssertFalse(desc.explainer.isEmpty)
    }

    // MARK: - Caching

    func testResultsAreCachedByPath() {
        // Same path resolves to the same result twice — a stand-in for
        // "we don't re-read Info.plist every tick." Verified by observing
        // that two calls return the same description.
        let descriptor = ProcessDescriptor()
        let p = proc("Slack", path: "/Applications/Slack.app/Contents/MacOS/Slack")
        let a = descriptor.describe(p)
        let b = descriptor.describe(p)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.friendlyName, "Slack")
    }
}
