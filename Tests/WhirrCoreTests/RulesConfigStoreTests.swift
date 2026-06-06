import XCTest
@testable import WhirrCore

final class RulesConfigStoreTests: XCTestCase {
    private var tmpDir: URL!
    private var path: String!
    private var store: RulesConfigStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhirrRulesConfigTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        path = tmpDir.appendingPathComponent("rules.json").path
        store = RulesConfigStore(path: path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try super.tearDownWithError()
    }

    // MARK: - Load

    func testAbsentFileReturnsDefaultsWithAbsentResult() {
        let (config, result) = store.load()
        XCTAssertEqual(config, .default)
        XCTAssertEqual(result, .absent)
    }

    func testRoundTripPreservesEditedThresholds() throws {
        let edited = RulesConfig(
            swapThrashing: SwapThrashingRuleConfig(enabled: true, warningGB: 8, criticalGB: 24)
        )
        try store.write(edited)
        let (loaded, result) = store.load()
        XCTAssertEqual(result, .loaded)
        XCTAssertEqual(loaded.swapThrashing.warningGB, 8)
        XCTAssertEqual(loaded.swapThrashing.criticalGB, 24)
        // Untouched rules still match defaults.
        XCTAssertEqual(loaded.lowDiskSpace, .init())
    }

    func testPartialConfigKeepsDefaultsForUnmentionedKeys() throws {
        // User edits one threshold and leaves the rest of the file empty.
        let json = """
        { "formatVersion": 1, "swapThrashing": { "warningGB": 12 } }
        """
        try json.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        let (loaded, result) = store.load()
        XCTAssertEqual(result, .loaded)
        XCTAssertEqual(loaded.swapThrashing.warningGB, 12)
        // Defaults preserved for missing keys.
        XCTAssertEqual(loaded.swapThrashing.criticalGB, 6.0)
        XCTAssertTrue(loaded.swapThrashing.enabled)
        XCTAssertEqual(loaded.lowDiskSpace.warningPercentUsed, 85)
    }

    func testMalformedJSONFallsBackToDefaults() throws {
        let junk = Data("{ not json at all".utf8)
        try junk.write(to: URL(fileURLWithPath: path))
        let (config, result) = store.load()
        XCTAssertEqual(config, .default)
        if case .malformed = result {} else {
            XCTFail("expected .malformed, got \(result)")
        }
    }

    func testFormatVersionMismatchFallsBack() throws {
        let json = """
        { "formatVersion": 99 }
        """
        try json.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        let (config, result) = store.load()
        XCTAssertEqual(config, .default)
        XCTAssertEqual(result, .versionMismatch(actual: 99))
    }

    // MARK: - WriteDefaults

    func testWriteDefaultsCreatesParentDirectory() throws {
        // Place the file in a nested directory that doesn't exist yet.
        let nested = tmpDir.appendingPathComponent("a/b/c/rules.json").path
        let nestedStore = RulesConfigStore(path: nested)
        try nestedStore.writeDefaults()
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested))
    }

    func testWriteDefaultsIsPrettyPrinted() throws {
        try store.writeDefaults()
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let asString = String(decoding: data, as: UTF8.self)
        // Pretty-printed → has at least one newline + indentation.
        XCTAssertTrue(asString.contains("\n  "), "Expected pretty-printed JSON, got: \(asString.prefix(80))")
    }
}
