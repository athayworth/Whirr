import XCTest
@testable import WhirrCore

final class HistoryDigestTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    private var now: Date { at(day: 0, hour: 15) }

    /// `day` 0 = 2026-10-17 (today), -1 = yesterday, …
    private func at(day: Int, hour: Int, minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 17 + day, hour: hour, minute: minute))!
    }

    private func outage(day: Int, hour: Int, minutes: Int = 1, cause: OutageCause = .isp, method: Int = 2,
                        network: String = "h") -> OutageRecord {
        OutageRecord(start: at(day: day, hour: hour), end: at(day: day, hour: hour, minute: minutes),
                     cause: cause, networkId: network, causeMethod: method)
    }

    private func incident(_ title: String, day: Int, hour: Int, hours: Double, culprits: [String] = [],
                          tier: Diagnosis.Tier = .problem, area: Diagnosis.Area = .mac) -> DiagnosisIncident {
        let start = at(day: day, hour: hour)
        return DiagnosisIncident(title: title, peakSeverity: .warning, firstSeenAt: start,
                                 lastSeenAt: start.addingTimeInterval(hours * 3600), culprits: culprits, tier: tier, area: area)
    }

    private func digest(incidents: [DiagnosisIncident] = [], outages: [OutageRecord] = [],
                        changes: [ChannelChange] = []) -> HistoryDigest {
        HistoryDigest.compute(incidents: incidents, outages: outages, changes: changes, networkId: "h", now: now, calendar: cal)
    }

    func testQuietWeek() {
        XCTAssertEqual(digest().weekSentence, "A quiet week: no outages and no Mac problems.")
        XCTAssertTrue(digest().days.isEmpty)
    }

    func testOutageTotals() {
        let d = digest(outages: [outage(day: 0, hour: 1, minutes: 2), outage(day: -2, hour: 14, minutes: 1)])
        XCTAssertTrue(d.weekSentence.hasPrefix("This week: 2 outages (3 min total)"), d.weekSentence)
        XCTAssertFalse(d.weekSentence.contains("9 pm"), d.weekSentence)
    }

    func testNightClauseOnlyWithEnoughReliableOutages() {
        let night = (1...3).map { outage(day: -$0, hour: 23) }
        XCTAssertTrue(digest(outages: night).weekSentence.contains("3 of them between 9 pm and 3 am"),
                      digest(outages: night).weekSentence)
        let old = (1...3).map { outage(day: -$0, hour: 23, method: 1) }
        XCTAssertFalse(digest(outages: old).weekSentence.contains("between 9 pm"))
        XCTAssertFalse(digest(outages: Array(night.prefix(2))).weekSentence.contains("between 9 pm"))
        let mixed = night + [outage(day: -4, hour: 12), outage(day: -5, hour: 12)]
        XCTAssertFalse(digest(outages: mixed).weekSentence.contains("between 9 pm"), "3 of 5 is under two-thirds")
    }

    func testLongestMacProblemAndItsOwnerOnlyWhenNamed() {
        let d = digest(incidents: [incident(DiagnosisTitles.overloaded, day: -1, hour: 13, hours: 2, culprits: ["com.docker.backend"]),
                                   incident(DiagnosisTitles.overloaded, day: 0, hour: 13, hours: 1, culprits: ["com.docker.backend"]),
                                   incident(DiagnosisTitles.memoryTight, day: 0, hour: 9, hours: 0.5)])
        XCTAssertTrue(d.weekSentence.contains("System is overloaded (3 h in total)"), d.weekSentence)
        XCTAssertTrue(d.weekSentence.contains("mostly with Docker involved"), d.weekSentence)
        let noOwner = digest(incidents: [incident(DiagnosisTitles.overloaded, day: 0, hour: 13, hours: 2)])
        XCTAssertFalse(noOwner.weekSentence.contains("involved"), noOwner.weekSentence)
    }

    func testNotesAndOutageIncidentsNeverAppearAsProblems() {
        let d = digest(incidents: [incident(DiagnosisTitles.swapVolumeOnly, day: 0, hour: 9, hours: 5, tier: .note),
                                   incident(ConnectionTitles.outage, day: 0, hour: 9, hours: 0.1, area: .connection)])
        XCTAssertEqual(d.weekSentence, "A quiet week: no outages and no Mac problems.")
        XCTAssertTrue(d.days.isEmpty)
    }

    func testDaysAndEventsNewestFirstWithSummaries() {
        let d = digest(incidents: [incident(DiagnosisTitles.overloaded, day: 0, hour: 13, hours: 1)],
                       outages: [outage(day: 0, hour: 0, minutes: 1), outage(day: -1, hour: 22, minutes: 6)])
        XCTAssertEqual(d.days.map(\.day), [at(day: 0, hour: 0), at(day: -1, hour: 0)])
        XCTAssertEqual(d.days[0].events.map(\.at), [at(day: 0, hour: 13), at(day: 0, hour: 0)])
        XCTAssertEqual(d.days[0].summary, "1 outage (1 min) · System is overloaded for 1 h")
        XCTAssertEqual(d.days[0].events.first?.kind, .mac)
        XCTAssertEqual(d.days[1].events.first?.text, "Down beyond the router")
    }

    func testOlderMethodFlaggedPerDay() {
        let d = digest(outages: [outage(day: 0, hour: 1, method: 1), outage(day: -1, hour: 1)])
        XCTAssertTrue(d.days[0].hasOlderMethodOutages)
        XCTAssertFalse(d.days[1].hasOlderMethodOutages)
    }

    func testChannelChangesAreWiFiEvents() {
        let change = ChannelChange(from: LinkPoint(band: "5 GHz", channel: 36, widthMHz: 80),
                                   to: LinkPoint(band: "5 GHz", channel: 157, widthMHz: 80), at: at(day: -2, hour: 21), notBefore: nil)
        let d = digest(changes: [change])
        XCTAssertEqual(d.days.first?.events.first?.kind, .wifi)
        XCTAssertTrue(d.days.first?.summary.contains("Wi-Fi channel changed") ?? false)
    }

    func testOtherNetworksAndOlderThanAWeekExcluded() {
        let d = digest(outages: [outage(day: 0, hour: 1, network: "cafe"), outage(day: -8, hour: 1)])
        XCTAssertEqual(d.weekSentence, "A quiet week: no outages and no Mac problems.")
    }

    func testPatternsNeedThreeDays() {
        let three = (0..<3).map { incident(DiagnosisTitles.overloaded, day: -$0, hour: 13, hours: 0.5) }  // 30 min each
        XCTAssertEqual(digest(incidents: three).patterns, ["System is overloaded on 3 of the last 7 days"])
        XCTAssertTrue(digest(incidents: Array(three.prefix(2))).patterns.isEmpty)
        let outs = (0..<4).map { outage(day: -$0, hour: 12) }
        XCTAssertEqual(digest(outages: outs).patterns, ["Outages on 4 of the last 7 days"])
    }

    func testFlickersThatNeverPassedTheTwoMinuteGateAreLeftOut() {
        let brief = incident(DiagnosisTitles.overloaded, day: 0, hour: 13, hours: 5.0 / 3600)   // 5 s
        let real = incident(DiagnosisTitles.memoryTight, day: 0, hour: 9, hours: 0.5)
        let d = digest(incidents: [brief, real])
        XCTAssertEqual(d.days.first?.events.map(\.text), [DiagnosisTitles.memoryTight])
    }

    func testOwnerClauseIsNotRepeatedWhenTheTitleAlreadyNamesIt() {
        let vm = "Virtualization VM (probably Docker)"
        let d = digest(incidents: [incident("\(vm) has been pegging CPU", day: 0, hour: 13, hours: 2, culprits: [vm])])
        XCTAssertFalse(d.weekSentence.contains("involved"), d.weekSentence)
        XCTAssertFalse(d.days.first?.events.first?.text.contains("(") == true
                       && d.days.first?.events.first?.text.hasSuffix("(\(vm))") == true)
    }

    func testRepeatsWithinADayFoldIntoOneRow() {
        let d = digest(incidents: [incident("Graphics is working hard", day: 0, hour: 9, hours: 0.1, culprits: ["WindowServer"]),
                                   incident("Graphics is working hard", day: 0, hour: 11, hours: 0.2, culprits: ["WindowServer"]),
                                   incident("Graphics is working hard", day: -1, hour: 11, hours: 0.2, culprits: ["WindowServer"])])
        let today = d.days.first!
        XCTAssertEqual(today.events.count, 1)
        XCTAssertEqual(today.events[0].text, "Graphics is working hard (WindowServer) — 2 times")
        XCTAssertEqual(today.events[0].durationSeconds, 1080)
        XCTAssertEqual(today.events[0].at, at(day: 0, hour: 11))
        XCTAssertEqual(d.days[1].events.count, 1)
    }

    func testRawProcessNamesReadAsFriendlyNames() {
        let d = digest(incidents: [incident(DiagnosisTitles.diskBusy, day: 0, hour: 9, hours: 0.1,
                                            culprits: ["com.apple.Virtualization.Virtua"])])
        XCTAssertEqual(d.days.first?.events.first?.text, "Disk is busy (Virtualization VM)")
    }

    func testDaySummaryUsesTheSameTotalsAsTheRows() {
        let d = digest(incidents: [incident(DiagnosisTitles.memoryTight, day: 0, hour: 8, hours: 1),
                                   incident(DiagnosisTitles.overloaded, day: 0, hour: 10, hours: 0.75),
                                   incident(DiagnosisTitles.overloaded, day: 0, hour: 12, hours: 0.75)])
        XCTAssertEqual(d.days.first?.summary, "System is overloaded — 2 times for 1 h 30 min")
    }
}
