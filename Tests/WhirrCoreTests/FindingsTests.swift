import XCTest
@testable import WhirrCore

/// The classifier decides what's a *problem* (colors the icon, can
/// headline, can notify) versus a *note* (true but not urgent). Getting
/// this wrong is exactly the cry-wolf failure the redesign exists to fix.
final class FindingsTests: XCTestCase {
    private func d(_ title: String, _ severity: Severity = .warning, kind: Diagnosis.Kind = .standalone) -> Diagnosis {
        Diagnosis(title: title, detail: "x", severity: severity, kind: kind)
    }

    private func classify(_ ds: [Diagnosis]) -> [String: Diagnosis] {
        Dictionary(uniqueKeysWithValues: FindingClassifier.classify(ds).map { ($0.title, $0) })
    }

    func testDefaultsAreMacProblemWithoutAction() {
        let out = classify([d(DiagnosisTitles.memoryTight)])[DiagnosisTitles.memoryTight]!
        XCTAssertEqual(out.tier, .problem)
        XCTAssertEqual(out.area, .mac)
        XCTAssertNil(out.action)
    }

    func testParkedSwapIsANote() {
        XCTAssertEqual(classify([d(DiagnosisTitles.swapVolumeOnly)])[DiagnosisTitles.swapVolumeOnly]?.tier, .note)
    }

    func testDiskNearlyFullWarningIsNoteCriticalIsProblemWithHowTo() {
        XCTAssertEqual(classify([d(DiagnosisTitles.lowDisk, .warning)])[DiagnosisTitles.lowDisk]?.tier, .note)
        let crit = classify([d(DiagnosisTitles.lowDisk, .critical)])[DiagnosisTitles.lowDisk]!
        XCTAssertEqual(crit.tier, .problem)
        XCTAssertEqual(crit.action?.kind, .showHowTo(.freeDiskSpace))
    }

    func testIdleHogsIsANote() {
        XCTAssertEqual(classify([d(DiagnosisTitles.idleHogs, kind: .narrative)])[DiagnosisTitles.idleHogs]?.tier, .note)
    }

    func testDockerAloneIsADeveloperNote() {
        let out = classify([d(DiagnosisTitles.dockerStrain, .critical, kind: .narrative)])[DiagnosisTitles.dockerStrain]!
        XCTAssertEqual(out.area, .developer)
        XCTAssertEqual(out.tier, .note)
        XCTAssertNil(out.action)
    }

    func testDockerAsAMinorShareStaysANoteEvenUnderStrain() {
        // The strain could be an Xcode build; Docker using a small share
        // of the Mac isn't evidence that Docker caused it.
        let out = classify([d(DiagnosisTitles.dockerStrain, .critical, kind: .narrative),
                            d(DiagnosisTitles.overloaded)])[DiagnosisTitles.dockerStrain]!
        XCTAssertEqual(out.tier, .note)
        XCTAssertEqual(out.area, .developer)
        XCTAssertNil(out.action)
    }

    func testDockerAsAMajorLoadAloneIsADeveloperNote() {
        let out = classify([d(DiagnosisTitles.dockerMajorLoad, .warning, kind: .narrative)])[DiagnosisTitles.dockerMajorLoad]!
        XCTAssertEqual(out.tier, .note)
        XCTAssertEqual(out.area, .developer)
    }

    func testDockerEscalatesToMacProblemWhenSystemIsStrained() {
        for strain in [DiagnosisTitles.overloaded, DiagnosisTitles.memorySaturated,
                       DiagnosisTitles.swapActivelyPaging, DiagnosisTitles.thermalWarning,
                       DiagnosisTitles.thermalCritical] {
            let out = classify([d(DiagnosisTitles.dockerMajorLoad, .critical, kind: .narrative), d(strain)])[DiagnosisTitles.dockerMajorLoad]!
            XCTAssertEqual(out.area, .mac, strain)
            XCTAssertEqual(out.tier, .problem, strain)
            XCTAssertEqual(out.action?.kind, .stopDocker, strain)
        }
    }

    func testDockerStaysNoteWhenOnlyMemoryTight() {
        let out = classify([d(DiagnosisTitles.dockerStrain, kind: .narrative), d(DiagnosisTitles.memoryTight)])[DiagnosisTitles.dockerStrain]!
        XCTAssertEqual(out.tier, .note)
    }

    func testClassifyPreservesIdentityAndOrder() {
        let input = [d("A"), d(DiagnosisTitles.swapVolumeOnly), d("B")]
        let out = FindingClassifier.classify(input)
        XCTAssertEqual(out.map(\.id), input.map(\.id))
    }

    func testEngineAppliesClassifier() {
        let snapshot = SystemSnapshot(
            memoryUsedBytes: 0, memoryAvailableBytes: 0, memoryPressure: .warning,
            swapUsedBytes: 4 * 1_073_741_824, thermalState: .nominal, loadAverage: .zero
        )
        let out = RulesEngine().evaluate(snapshot: snapshot, processes: [])
        XCTAssertEqual(out.first { $0.title == DiagnosisTitles.swapVolumeOnly }?.tier, .note)
    }

    func testOldDiagnosisJSONDecodesWithDefaults() throws {
        let json = #"{"id":"6F3B5B8E-0D6B-4E3C-9B39-0E7E2C1F0A11","title":"t","detail":"d","severity":1}"#
        let out = try JSONDecoder().decode(Diagnosis.self, from: Data(json.utf8))
        XCTAssertEqual(out.tier, .problem)
        XCTAssertEqual(out.area, .mac)
        XCTAssertNil(out.action)
    }

    func testActionRoundTrips() throws {
        let original = Diagnosis(title: "t", detail: "d", severity: .warning,
                                 tier: .problem, area: .connection,
                                 action: SuggestedAction(label: "Change channel", kind: .showHowTo(.changeWiFiChannel)))
        let decoded = try JSONDecoder().decode(Diagnosis.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }
}
