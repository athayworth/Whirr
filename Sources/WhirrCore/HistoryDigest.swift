import Foundation

public struct HistoryEvent: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case mac, connection, wifi }
    public let id: String
    public let at: Date
    public let kind: Kind
    public let text: String
    public let durationSeconds: Int?
}

public struct HistoryDay: Sendable, Equatable, Identifiable {
    /// Start of the local day.
    public let day: Date
    public var id: Date { day }
    /// "6 outages (6 min) · System is overloaded for 2 h 10 min"
    public let summary: String
    /// Newest first.
    public let events: [HistoryEvent]
    /// Some of this day's outages had their cause judged by the older
    /// single-check method.
    public let hasOlderMethodOutages: Bool
}

/// The last week, told compactly: one sentence, then the days. Every
/// claim is a count Whirr can make from what it recorded.
public struct HistoryDigest: Sendable, Equatable {
    public let weekSentence: String
    /// Newest first.
    public let days: [HistoryDay]
    public let patterns: [String]

    static let windowDays = 7
    static let nightHours: Set<Int> = [21, 22, 23, 0, 1, 2]

    public static func compute(incidents: [DiagnosisIncident], outages: [OutageRecord], changes: [ChannelChange],
                               networkId: String?, now: Date, calendar: Calendar = .current) -> HistoryDigest {
        let since = calendar.date(byAdding: .day, value: -(windowDays - 1), to: calendar.startOfDay(for: now))!

        let problems = incidents.filter {
            $0.tier == .problem && $0.title != ConnectionTitles.outage && $0.lastSeenAt >= since && $0.firstSeenAt <= now
        }
        let outs = outages.filter {
            (networkId == nil || $0.networkId == networkId) && $0.start >= since && $0.start <= now
        }
        let chs = changes.filter { $0.at >= since && $0.at <= now }

        // MARK: Events
        var events: [HistoryEvent] = []
        for i in problems {
            let owner = i.culprits.first.map {
                CulpritOwner.owner(of: $0, dockerRunning: i.culprits.contains { $0.hasPrefix("com.docker.") })
            }
            let text = owner.map { i.title.contains($0) ? i.title : "\(i.title) (\($0))" } ?? i.title
            events.append(HistoryEvent(id: i.id.uuidString, at: i.firstSeenAt,
                                       kind: i.area == .connection ? .connection : .mac,
                                       text: text, durationSeconds: i.durationSeconds))
        }
        for o in outs {
            events.append(HistoryEvent(id: o.id.uuidString, at: o.start, kind: .connection,
                                       text: shortCause(o.cause), durationSeconds: o.duration.map { Int($0) }))
        }
        for c in chs {
            events.append(HistoryEvent(id: "change-\(c.at.timeIntervalSince1970)", at: c.at, kind: .wifi,
                                       text: c.description, durationSeconds: nil))
        }

        // MARK: Days
        let byDay = Dictionary(grouping: events) { calendar.startOfDay(for: $0.at) }
        let days = byDay.keys.sorted(by: >).map { day -> HistoryDay in
            let dayEvents = byDay[day]!.sorted { $0.at > $1.at }
            let dayOutages = outs.filter { calendar.startOfDay(for: $0.start) == day }
            let dayProblems = problems.filter { calendar.startOfDay(for: $0.firstSeenAt) == day && $0.area != .connection }
            var pieces: [String] = []
            if !dayOutages.isEmpty {
                pieces.append("\(count(dayOutages.count, "outage")) (\(DurationText.words(seconds: totalSeconds(dayOutages))))")
            }
            if let longest = dayProblems.max(by: { $0.durationSeconds < $1.durationSeconds }) {
                pieces.append("\(longest.title) for \(DurationText.words(seconds: longest.durationSeconds))")
            }
            if chs.contains(where: { calendar.startOfDay(for: $0.at) == day }) {
                pieces.append("Wi-Fi channel changed")
            }
            return HistoryDay(day: day, summary: pieces.joined(separator: " · "), events: dayEvents,
                              hasOlderMethodOutages: dayOutages.contains { !$0.causeIsReliable })
        }

        // MARK: Week sentence
        let macProblems = problems.filter { $0.area != .connection }
        var sentences: [String] = []
        if !outs.isEmpty {
            var s = "\(count(outs.count, "outage")) (\(DurationText.words(seconds: totalSeconds(outs))) total)"
            let reliable = outs.filter(\.causeIsReliable)
            let night = reliable.filter { nightHours.contains(calendar.component(.hour, from: $0.start)) }
            if reliable.count >= 3, Double(night.count) >= Double(reliable.count) * 2 / 3 {
                s += reliable.count == outs.count
                    ? ", \(night.count) of them between 9 pm and 3 am"
                    : ", \(night.count) of the \(reliable.count) checked with the current method between 9 pm and 3 am"
            }
            sentences.append(s)
        } else if !macProblems.isEmpty {
            sentences.append("No outages")
        }
        if !macProblems.isEmpty {
            let byTitle = Dictionary(grouping: macProblems, by: \.title)
            let (title, list) = byTitle.max { totalSeconds($0.value) < totalSeconds($1.value) }!
            let total = totalSeconds(list)
            var s = "Longest-running Mac problem: \(title) (\(DurationText.words(seconds: total)) in total)"
            if let owner = dominantOwner(list, total: total) { s += ", mostly with \(owner) involved" }
            sentences.append(s)
        }
        let week = sentences.isEmpty
            ? "A quiet week: no outages and no Mac problems."
            : "This week: " + sentences.joined(separator: ". ") + "."

        // MARK: Patterns
        var patterns: [String] = []
        let titleDays = Dictionary(grouping: problems, by: \.title)
            .mapValues { Set($0.map { calendar.startOfDay(for: $0.firstSeenAt) }).count }
        for (title, n) in titleDays.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) where n >= 3 {
            patterns.append("\(title) on \(n) of the last \(windowDays) days")
        }
        let outageDays = Set(outs.map { calendar.startOfDay(for: $0.start) }).count
        if outageDays >= 3 { patterns.append("Outages on \(outageDays) of the last \(windowDays) days") }

        return HistoryDigest(weekSentence: week, days: days, patterns: patterns)
    }

    /// The owner named in the incidents covering at least two-thirds of
    /// the time, if any.
    private static func dominantOwner(_ list: [DiagnosisIncident], total: Int) -> String? {
        guard total > 0 else { return nil }
        var time: [String: Int] = [:]
        for i in list {
            let docker = i.culprits.contains { $0.hasPrefix("com.docker.") }
            for owner in Set(i.culprits.map { CulpritOwner.owner(of: $0, dockerRunning: docker) }) {
                time[owner, default: 0] += i.durationSeconds
            }
        }
        guard let (owner, t) = time.max(by: { $0.value < $1.value }), Double(t) >= Double(total) * 2 / 3 else { return nil }
        return owner
    }

    static func shortCause(_ c: OutageCause) -> String {
        switch c {
        case .router: return "Router stopped responding"
        case .isp: return "Down beyond the router"
        case .wifiDisconnected: return "Wi-Fi disconnected"
        case .unknown: return "Connection down (cause unclear)"
        }
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
    private static func totalSeconds(_ o: [OutageRecord]) -> Int { o.compactMap(\.duration).map { Int($0) }.reduce(0, +) }
    private static func totalSeconds(_ i: [DiagnosisIncident]) -> Int { i.map(\.durationSeconds).reduce(0, +) }
}
