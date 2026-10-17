import Foundation

/// One cause, told once: the findings that share a culprit owner (or a
/// system-wide effect that owner measurably drives), with the most
/// serious one as the headline.
public struct Story: Sendable, Hashable, Identifiable {
    public let headline: DiagnosisContext
    /// Every finding in the story, headline first.
    public let members: [DiagnosisContext]
    public let owner: String?

    public var id: String { headline.diagnosis.title }
    public var area: Diagnosis.Area { headline.diagnosis.area }
    public var action: SuggestedAction? { headline.diagnosis.action }
    /// The short "because" — the headline's first measured fact.
    public var because: String? { headline.diagnosis.evidence.first }
    public var impact: String? { headline.diagnosis.impact }
    public var phrase: String { StoryPhrases.phrase(for: headline.diagnosis.title) }
    public var durationSeconds: Int { headline.durationSeconds }
    public var isProblem: Bool { headline.diagnosis.tier == .problem }
    public var titles: [String] { members.map(\.diagnosis.title) }

    /// How Whirr knows: the headline's evidence, then each other member's
    /// first fact, labelled with its title.
    public var evidence: [String] {
        headline.diagnosis.evidence + members.dropFirst().compactMap { m in
            m.diagnosis.evidence.first.map { "\(m.diagnosis.title): \($0)" }
        }
    }
}

public enum StoryBuilder {
    /// Effects of CPU load: join the owner using the most CPU.
    static let cpuEffects: Set<String> = [DiagnosisTitles.overloaded, DiagnosisTitles.thermalWarning,
                                          DiagnosisTitles.thermalCritical]
    /// Effects of memory use: join the owner holding the most memory.
    static let memoryEffects: Set<String> = [DiagnosisTitles.memorySaturated, DiagnosisTitles.memoryTight,
                                             DiagnosisTitles.swapActivelyPaging]
    static let minCPUShare = 0.4
    static let minMemoryShare = 0.25

    public static func build(_ contexts: [DiagnosisContext], load: OwnerLoad) -> [Story] {
        var groups: [(owner: String?, members: [DiagnosisContext])] = []
        var effects: [DiagnosisContext] = []

        for c in contexts {
            let title = c.diagnosis.title
            if cpuEffects.contains(title) || memoryEffects.contains(title) {
                effects.append(c)
                continue
            }
            guard let culprit = c.diagnosis.culprits.first else {
                groups.append((nil, [c]))
                continue
            }
            let owner = CulpritOwner.owner(of: culprit, dockerRunning: load.dockerRunning)
            if let i = groups.firstIndex(where: { $0.owner == owner }) {
                groups[i].members.append(c)
            } else {
                groups.append((owner, [c]))
            }
        }

        // A system-wide effect joins an owner's story only when that owner
        // already has a finding *and* is measurably the biggest contributor.
        for e in effects {
            let cpu = cpuEffects.contains(e.diagnosis.title)
            let shares = cpu ? load.cpuShare : load.memoryShare
            let threshold = cpu ? minCPUShare : minMemoryShare
            let trusted = cpu ? load.seesAllProcesses : true
            let candidates = groups.indices.filter { groups[$0].owner != nil }
            let best = candidates.max { (shares[groups[$0].owner!] ?? 0) < (shares[groups[$1].owner!] ?? 0) }
            if trusted, let best, (shares[groups[best].owner!] ?? 0) >= threshold,
               (shares[groups[best].owner!] ?? 0) == (shares.values.max() ?? 0) {
                groups[best].members.append(e)
            } else {
                groups.append((nil, [e]))
            }
        }

        let stories = groups.map { group -> Story in
            let ordered = group.members.sorted(by: headlineFirst)
            return Story(headline: ordered[0], members: ordered, owner: group.owner)
        }
        return stories.sorted { VerdictSelector.isMoreImportant($0.headline, $1.headline) }
    }

    /// Problems before notes, then the verdict's own importance order.
    static func headlineFirst(_ a: DiagnosisContext, _ b: DiagnosisContext) -> Bool {
        let ap = a.diagnosis.tier == .problem, bp = b.diagnosis.tier == .problem
        if ap != bp { return ap }
        return VerdictSelector.isMoreImportant(a, b)
    }

    /// "Your Mac is overloaded, and your link to the router is stalling."
    /// Problem stories only; nil when there are none.
    public static func sentence(_ stories: [Story]) -> String? {
        let phrases = stories.filter(\.isProblem).map(\.phrase)
        guard !phrases.isEmpty else { return nil }
        let shown = Array(phrases.prefix(3))
        let extra = phrases.count - shown.count
        var parts = shown
        if extra > 0 { parts.append("\(extra) more") }
        let body: String
        switch parts.count {
        case 1: body = parts[0]
        case 2: body = "\(parts[0]), and \(parts[1])"
        default: body = parts.dropLast().joined(separator: ", ") + ", and " + parts.last!
        }
        return body.prefix(1).uppercased() + body.dropFirst() + "."
    }
}

/// Short lowercase clause per finding, for the combined sentence. Says no
/// more than the finding's title does.
public enum StoryPhrases {
    static let table: [String: String] = [
        DiagnosisTitles.overloaded: "your Mac is overloaded",
        DiagnosisTitles.memorySaturated: "memory is saturated",
        DiagnosisTitles.memoryTight: "memory is getting tight",
        DiagnosisTitles.swapActivelyPaging: "your Mac is paging memory to disk",
        DiagnosisTitles.thermalWarning: "your Mac is slowing down from heat",
        DiagnosisTitles.thermalCritical: "your Mac is slowing down from heat",
        DiagnosisTitles.lowDisk: "your disk is nearly full",
        DiagnosisTitles.diskBusy: "the disk is very busy",
        DiagnosisTitles.dockerMajorLoad: "Docker is weighing your Mac down",
        DiagnosisTitles.dockerStrain: "Docker is using significant resources",
        DiagnosisTitles.backupUsing: "a backup is running",
        "Backup is competing with your apps": "a backup is competing with your apps",
        "Memory + swap death spiral": "memory is full and your Mac is paging hard",
        "Heavy work while your Mac is hot": "heavy work is running while your Mac is hot",
        "Heavy disk use while memory is tight": "heavy disk use is meeting tight memory",
        "Graphics is working hard": "graphics is working hard",
        "Spotlight is indexing": "Spotlight is indexing",
        ConnectionTitles.spikyWiFi: "your link to the router is stalling",
        ConnectionTitles.pastRouter: "the connection beyond your router is stalling",
        ConnectionTitles.weakSignal: "your Wi-Fi signal is weak",
        ConnectionTitles.outage: "the internet is down",
    ]

    public static func phrase(for title: String) -> String {
        if let p = table[title] { return p }
        if title.hasSuffix(" " + DiagnosisTitles.runawaySuffix) {
            return String(title.dropLast(DiagnosisTitles.runawaySuffix.count + 1)) + " is using a lot of CPU"
        }
        if title.hasSuffix(" memory has been growing") {
            return String(title.dropLast(" memory has been growing".count)) + "'s memory has been growing"
        }
        return title.prefix(1).lowercased() + title.dropFirst()
    }
}
