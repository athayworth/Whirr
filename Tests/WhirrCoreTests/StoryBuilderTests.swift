import XCTest
@testable import WhirrCore

final class StoryBuilderTests: XCTestCase {
    private func ctx(_ title: String, _ sev: Severity = .critical, culprits: [String] = [], tier: Diagnosis.Tier = .problem,
                     secs: Int = 600, evidence: [String] = ["e"]) -> DiagnosisContext {
        DiagnosisContext(diagnosis: Diagnosis(title: title, detail: "", severity: sev, culprits: culprits, tier: tier)
                            .explained(evidence: evidence, impact: "i"),
                         firstSeenAt: Date(), durationSeconds: secs, trend: .stable, peakSeverity: sev)
    }
    private let dockerHeavy = OwnerLoad(cpuShare: ["Docker": 0.42], memoryShare: ["Docker": 0.31],
                                        seesAllProcesses: true, dockerRunning: true)

    func testSameOwnerMergesIntoOneStory() {
        let s = StoryBuilder.build([ctx(DiagnosisTitles.dockerMajorLoad, culprits: ["com.docker.backend"]),
                                    ctx("Virtualization VM (probably Docker) has been pegging CPU",
                                        culprits: ["Virtualization VM (probably Docker)"])],
                                   load: dockerHeavy)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].owner, "Docker")
        XCTAssertEqual(s[0].members.count, 2)
    }

    func testOverloadedJoinsOnlyTheMeasuredBiggestContributor() {
        let joined = StoryBuilder.build([ctx(DiagnosisTitles.dockerMajorLoad, culprits: ["com.docker.backend"]),
                                         ctx(DiagnosisTitles.overloaded)], load: dockerHeavy)
        XCTAssertEqual(joined.count, 1)
        let small = OwnerLoad(cpuShare: ["Docker": 0.2], memoryShare: ["Docker": 0.1], seesAllProcesses: true, dockerRunning: true)
        XCTAssertEqual(StoryBuilder.build([ctx(DiagnosisTitles.dockerMajorLoad, culprits: ["com.docker.backend"]),
                                           ctx(DiagnosisTitles.overloaded)], load: small).count, 2)
        let blind = OwnerLoad(cpuShare: ["Docker": 0.9], memoryShare: [:], seesAllProcesses: false, dockerRunning: true)
        XCTAssertEqual(StoryBuilder.build([ctx(DiagnosisTitles.dockerMajorLoad, culprits: ["com.docker.backend"]),
                                           ctx(DiagnosisTitles.overloaded)], load: blind).count, 2)
    }

    func testSystemWideFindingNeverJoinsAnOwnerWithNoFindingOfItsOwn() {
        // Docker is the biggest CPU user but has no finding: "overloaded"
        // stays its own story rather than inventing a Docker story.
        let s = StoryBuilder.build([ctx(DiagnosisTitles.overloaded)], load: dockerHeavy)
        XCTAssertEqual(s.count, 1)
        XCTAssertNil(s[0].owner)
    }

    func testMemoryFindingJoinsOnMemoryShare() {
        let s = StoryBuilder.build([ctx(DiagnosisTitles.dockerMajorLoad, culprits: ["com.docker.backend"]),
                                    ctx(DiagnosisTitles.memoryTight, .warning)], load: dockerHeavy)
        XCTAssertEqual(s.count, 1)
    }

    func testHeadlineIsTheMostSeriousProblem() {
        let s = StoryBuilder.build([ctx("A", .warning, culprits: ["X"]), ctx("B", .critical, culprits: ["X"])], load: .empty)
        XCTAssertEqual(s.first?.headline.diagnosis.title, "B")
    }

    func testProblemOutranksANoteInTheSameStory() {
        let s = StoryBuilder.build([ctx("Note", .critical, culprits: ["X"], tier: .note),
                                    ctx("Problem", .warning, culprits: ["X"])], load: .empty)
        XCTAssertEqual(s.first?.headline.diagnosis.title, "Problem")
        XCTAssertTrue(s.first?.isProblem ?? false)
    }

    func testSentenceCombinesUpToThreeProblems() {
        let stories = StoryBuilder.build([ctx(DiagnosisTitles.overloaded), ctx(ConnectionTitles.spikyWiFi, .warning),
                                          ctx(DiagnosisTitles.lowDisk, .warning), ctx(DiagnosisTitles.thermalWarning, .warning)],
                                         load: .empty)
        let s = StoryBuilder.sentence(stories) ?? ""
        XCTAssertTrue(s.hasPrefix("Your Mac is overloaded"), s)
        XCTAssertTrue(s.contains("and 1 more"), s)
        XCTAssertTrue(s.hasSuffix("."), s)
    }

    func testTwoProblemSentenceReadsNaturally() {
        let stories = StoryBuilder.build([ctx(DiagnosisTitles.overloaded), ctx(ConnectionTitles.spikyWiFi, .warning)], load: .empty)
        XCTAssertEqual(StoryBuilder.sentence(stories), "Your Mac is overloaded, and your link to the router is stalling.")
    }

    func testNotesNeverMakeASentence() {
        XCTAssertNil(StoryBuilder.sentence(StoryBuilder.build([ctx(DiagnosisTitles.swapVolumeOnly, tier: .note)], load: .empty)))
    }

    func testStoryEvidenceIncludesMembers() {
        let s = StoryBuilder.build([ctx("A", culprits: ["X"], evidence: ["a1"]),
                                    ctx("B", .warning, culprits: ["X"], evidence: ["b1"])], load: .empty)
        XCTAssertEqual(s[0].evidence, ["a1", "B: b1"])
    }

    func testPhrasesNeverClaimMoreThanTheTitle() {
        XCTAssertEqual(StoryPhrases.phrase(for: "node has been pegging CPU"), "node is using a lot of CPU")
        XCTAssertEqual(StoryPhrases.phrase(for: "Xcode memory has been growing"), "Xcode's memory has been growing")
        XCTAssertEqual(StoryPhrases.phrase(for: "Something New"), "something New")
    }
}
