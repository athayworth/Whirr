import XCTest
@testable import WhirrCore

final class FinalReviewFixTests: XCTestCase {
    private func ctx(_ title: String, _ sev: Severity, secs: Int, culprits: [String] = [],
                     action: SuggestedAction? = nil) -> DiagnosisContext {
        DiagnosisContext(diagnosis: Diagnosis(title: title, detail: "", severity: sev, culprits: culprits, action: action),
                         firstSeenAt: Date(timeIntervalSince1970: 0), durationSeconds: secs, trend: .stable, peakSeverity: sev)
    }
    private let docker = OwnerLoad(cpuShare: ["Docker": 0.6], memoryShare: ["Docker": 0.3], seesAllProcesses: true, dockerRunning: true)

    // 1. Old incidents: notes stay notes, judged by their peak severity.
    func testOldNotesDecodeAsNotesUsingPeakSeverity() throws {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        func incident(_ title: String, peak: Int) throws -> DiagnosisIncident {
            let json = #"{"id":"7E3F1C2A-1111-4222-8333-444455556666","title":"\#(title)","peakSeverity":\#(peak),"firstSeenAt":"2026-10-15T06:00:00Z","lastSeenAt":"2026-10-15T09:00:00Z"}"#
            return try d.decode(DiagnosisIncident.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try incident(DiagnosisTitles.backupUsing, peak: 0).tier, .note)
        XCTAssertEqual(try incident(DiagnosisTitles.backupUsing, peak: 1).tier, .problem)
        XCTAssertEqual(try incident(DiagnosisTitles.lowDisk, peak: 1).tier, .note)
        XCTAssertEqual(try incident(DiagnosisTitles.lowDisk, peak: 2).tier, .problem)
        XCTAssertEqual(try incident(DiagnosisTitles.dockerMajorLoad, peak: 2).tier, .note)
    }

    // 2. A young member can't quiet an established story.
    func testNewMemberDoesNotPushAnEstablishedStoryBackToPending() {
        let v = VerdictSelector.select([ctx(DiagnosisTitles.dockerMajorLoad, .warning, secs: 1200, culprits: ["com.docker.backend"]),
                                        ctx(DiagnosisTitles.diskBusy, .critical, secs: 5, culprits: ["com.apple.Virtualization.Virtua"])],
                                       isHidden: { _ in false }, load: docker)
        XCTAssertEqual(v.stories.count, 1)
        XCTAssertEqual(v.headline?.diagnosis.title, DiagnosisTitles.dockerMajorLoad, "gated members lead")
        XCTAssertTrue(v.pendingStories.isEmpty)
    }

    // 3. A merged story keeps an action from any member.
    func testStoryKeepsAMembersActionAndCanNotify() {
        let stop = SuggestedAction(label: "Stop Docker containers", kind: .stopDocker)
        let s = StoryBuilder.build([ctx(DiagnosisTitles.dockerMajorLoad, .warning, secs: 600, culprits: ["com.docker.backend"], action: stop),
                                    ctx(DiagnosisTitles.overloaded, .critical, secs: 600)], load: docker)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].headline.diagnosis.title, DiagnosisTitles.overloaded)
        XCTAssertEqual(s[0].action, stop)
        XCTAssertTrue(VerdictSelector.shouldNotify(s[0]))
    }

    // 4. Quieting a story never silences system-wide findings forever.
    func testMuteTitlesExcludeJoinedSystemWideFindings() {
        let s = StoryBuilder.build([ctx(DiagnosisTitles.dockerMajorLoad, .warning, secs: 600, culprits: ["com.docker.backend"]),
                                    ctx(DiagnosisTitles.overloaded, .critical, secs: 600)], load: docker)
        XCTAssertEqual(s[0].muteTitles, [DiagnosisTitles.dockerMajorLoad])
        XCTAssertEqual(Set(s[0].titles), Set([DiagnosisTitles.dockerMajorLoad, DiagnosisTitles.overloaded]))
    }

    // 5. The connection only counts as checked once it has been measured.
    func testConnectionIsMeasuredOnlyWithSamplesAndNotPaused() {
        XCTAssertFalse(ConnectionSnapshot.empty.isMeasured)
        let h = HopStats(count: 30, medianMs: 5, p95Ms: nil, jitterMs: nil, lossPercent: 0, spikes: 0)
        func snap(paused: Bool) -> ConnectionSnapshot {
            ConnectionSnapshot(link: nil, isWired: true, gatewayPingable: true, networkId: "h", gateway1m: h, internet1m: h,
                               gateway10m: h, internet10m: h, currentOutage: nil, paused: paused)
        }
        XCTAssertTrue(snap(paused: false).isMeasured)
        XCTAssertFalse(snap(paused: true).isMeasured)
    }

    // 6. No "quiet week" without having watched.
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c
    }()

    func testQuietWeekOnlyWhenWhirrActuallyWatched() {
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 15))!
        let barely = HistoryDigest.compute(incidents: [], outages: [], changes: [], networkId: "h", now: now,
                                           watchedMinutes: 120, calendar: cal)
        XCTAssertEqual(barely.weekSentence, "Whirr has only watched for 2 h this week, and saw no outages or Mac problems in that time.")
        let enough = HistoryDigest.compute(incidents: [], outages: [], changes: [], networkId: "h", now: now,
                                           watchedMinutes: 3000, calendar: cal)
        XCTAssertEqual(enough.weekSentence, "A quiet week: no outages and no Mac problems.")
    }

    // 9. Only Backblaze's own processes are Backblaze.
    func testBzipIsNotBackblaze() {
        XCTAssertEqual(CulpritOwner.owner(of: "bzip2", dockerRunning: false), "bzip2")
        XCTAssertEqual(CulpritOwner.owner(of: "bztransmit", dockerRunning: false), "Backblaze")
    }

    // 12. Time before the week window isn't counted in it.
    func testIncidentsStartingBeforeTheWindowAreClipped() {
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 15))!
        let windowStart = cal.date(from: DateComponents(year: 2026, month: 10, day: 11))!
        let i = DiagnosisIncident(title: DiagnosisTitles.overloaded, peakSeverity: .warning,
                                  firstSeenAt: windowStart.addingTimeInterval(-3600), lastSeenAt: windowStart.addingTimeInterval(3600))
        let d = HistoryDigest.compute(incidents: [i], outages: [], changes: [], networkId: "h", now: now,
                                      watchedMinutes: 3000, calendar: cal)
        XCTAssertTrue(d.weekSentence.contains("(1 h in total)"), d.weekSentence)
        XCTAssertEqual(d.days.first?.day, windowStart)
    }

    // 10. Week sentence uses friendly names.
    func testWeekSentenceOwnerIsFriendly() {
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 15))!
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 9))!
        let i = DiagnosisIncident(title: DiagnosisTitles.diskBusy, peakSeverity: .warning, firstSeenAt: start,
                                  lastSeenAt: start.addingTimeInterval(3600), culprits: ["com.apple.Virtualization.Virtua"])
        let d = HistoryDigest.compute(incidents: [i], outages: [], changes: [], networkId: "h", now: now,
                                      watchedMinutes: 3000, calendar: cal)
        XCTAssertFalse(d.weekSentence.contains("com.apple"), d.weekSentence)
        XCTAssertTrue(d.weekSentence.contains("Virtualization VM"), d.weekSentence)
    }

    // 13. Impact copy doesn't assert the cause of what the person feels.
    func testImpactCopyIsHedged() {
        let engine = RulesEngine()
        let over = engine.evaluate(snapshot: SystemSnapshot(memoryUsedBytes: 8 << 30, memoryAvailableBytes: 8 << 30,
                                                           memoryPressure: .normal, swapUsedBytes: 0, thermalState: .nominal,
                                                           loadAverage: LoadAverage(oneMinute: 80, fiveMinute: 80, fifteenMinute: 80),
                                                           rootDiskFreeBytes: 500 << 30, rootDiskTotalBytes: 1000 << 30),
                                   processes: [])
        let impact = over.first { $0.title == DiagnosisTitles.overloaded }?.impact ?? ""
        XCTAssertFalse(impact.contains("that's the"), impact)
    }
}
