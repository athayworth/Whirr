import Foundation

extension Diagnosis {
    /// How loudly a finding should be presented.
    ///
    /// - `problem`: hurting performance now; can headline the Overview,
    ///   color the menu bar icon (after a duration gate), and notify.
    /// - `note`: true but not urgent ("swap is parked after a heavy
    ///   session"). Shown only inside its section; never colors the icon
    ///   or notifies. This split is what keeps the icon from crying wolf.
    public enum Tier: String, Codable, Sendable { case problem, note }

    /// Which sidebar section a finding belongs to.
    public enum Area: String, Codable, Sendable, CaseIterable { case mac, connection, developer }
}

/// A fix the UI can offer for a finding. Rules only *describe* the action;
/// the app maps each `Kind` to a handler.
public struct SuggestedAction: Hashable, Codable, Sendable {
    public enum Kind: Hashable, Codable, Sendable {
        case quitApp(pid: Int32)
        case stopDocker
        case openURL(URL)
        case openSection(Diagnosis.Area)
        case runConnectionTest
        case showHowTo(HowTo)
    }

    /// Plain-English instruction sheets for fixes Whirr can't perform
    /// itself (router settings, talking to the ISP).
    public enum HowTo: String, Hashable, Codable, Sendable {
        case changeWiFiChannel, talkToISP, improveSignal, freeDiskSpace
        case reinstallSampler, routerOutage, ispOutage, connectionDown
    }

    public let label: String
    public let kind: Kind

    public init(label: String, kind: Kind) {
        self.label = label
        self.kind = kind
    }
}

/// Post-pass over rule output that assigns tier, area and action by
/// title. Kept separate from the rules so each rule stays a pure
/// "is this condition present?" check, and so the presentation policy
/// lives in one reviewable place.
public enum FindingClassifier {
    /// Diagnoses that mean the whole system is genuinely struggling.
    /// Their presence is what turns "Docker is running" from a developer
    /// note into a Mac problem worth acting on.
    static let systemStrainTitles: Set<String> = [
        DiagnosisTitles.overloaded,
        DiagnosisTitles.memorySaturated,
        DiagnosisTitles.swapActivelyPaging,
        DiagnosisTitles.thermalWarning,
        DiagnosisTitles.thermalCritical
    ]

    public static func classify(_ diagnoses: [Diagnosis]) -> [Diagnosis] {
        let titles = Set(diagnoses.map(\.title))
        let systemStrained = !titles.isDisjoint(with: systemStrainTitles)
        return diagnoses.map { classify($0, systemStrained: systemStrained) }
    }

    private static func classify(_ d: Diagnosis, systemStrained: Bool) -> Diagnosis {
        switch d.title {
        case DiagnosisTitles.swapVolumeOnly, DiagnosisTitles.idleHogs:
            return d.classified(tier: .note, area: .mac, action: nil)
        case DiagnosisTitles.lowDisk:
            return d.severity == .critical
                ? d.classified(tier: .problem, area: .mac,
                               action: SuggestedAction(label: "How to free up space", kind: .showHowTo(.freeDiskSpace)))
                : d.classified(tier: .note, area: .mac, action: nil)
        case DiagnosisTitles.dockerStrain:
            return systemStrained
                ? d.classified(tier: .problem, area: .mac,
                               action: SuggestedAction(label: "Stop Docker containers", kind: .stopDocker))
                : d.classified(tier: .note, area: .developer, action: nil)
        default:
            return d
        }
    }
}
