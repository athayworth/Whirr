# Easy When Tired Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Whirr answer "is anything wrong, what, what do I do, and why" in one glance — one combined sentence and one action, an accurate "why" behind a button, short pages with detail folded away, and a compact day-grouped History.

**Architecture:** Rules gain `evidence` (measured facts) and `impact` (why it matters). A pure `StoryBuilder` merges findings that share a culprit owner into stories and builds the combined sentence; `VerdictSelector` gates stories instead of single findings. A pure `HistoryDigest` turns incidents, outages and channel changes into a week sentence and day groups. The SwiftUI views render stories; `SystemMonitor` sheds connection and navigation state into two small types.

**Tech Stack:** Swift 6.3, SwiftUI, SPM, XCTest. macOS 14+.

**Spec:** `docs/superpowers/specs/2026-10-17-easy-when-tired-design.md`

## Global Constraints

- Evidence-only rule: every user-visible claim must come from measurements in the same sample; general knowledge is framed as general ("Apps wait their turn when…"), never as a finding about this Mac.
- Durations shown in words via one formatter: "45 s", "17 min", "1 h 10 min" — never raw seconds above 59.
- No paths, pids or command lines outside the "How Whirr knows" panel.
- All new Codable fields decode tolerantly (`decodeIfPresent ?? default`).
- Sidebar stays flat: Overview, Mac, Connection, History, Developer, Learn.
- Notes never color the icon, never notify, never appear as History problems.
- Commit trailer on every commit:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01HiDwQQT7NE9ZDc6AnUwGXp`

## Review Focus

1. A system-wide finding (overloaded) when no story owner is the largest contributor — must stay its own story, never be pinned on Docker/Backblaze.
2. A story whose headline is snoozed/muted while another member is not — the story must use the visible members, or vanish only if all members are hidden.
3. Old incident data (no `tier`/`area`) and old daemon payloads (no `evidence`/`impact`) — decode and classify without inventing problems.
4. Week sentence with 1–2 outages, or all outages from the older method — must not claim a time-of-day pattern.
5. Calm state right after launch (no data yet) vs. genuinely calm — "All good" must never appear before the first sample or while something is pending.

---

### Task 1: Evidence and impact on findings; tier and area on incidents

**Files:**
- Modify: `Sources/WhirrCore/Models.swift` (Diagnosis)
- Modify: `Sources/WhirrCore/DiagnosisIncident.swift`
- Modify: `Sources/WhirrCore/DiagnosisDurationTracker.swift`
- Create: `Sources/WhirrCore/DurationText.swift`
- Test: `Tests/WhirrCoreTests/ExplanationModelTests.swift`

**Interfaces:**
- Produces: `Diagnosis.evidence: [String]`, `Diagnosis.impact: String?`, `Diagnosis.explained(evidence:impact:) -> Diagnosis` (same id), `DiagnosisIncident.tier: Diagnosis.Tier`, `DiagnosisIncident.area: Diagnosis.Area`, `DurationText.words(seconds: Int) -> String`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import WhirrCore

final class ExplanationModelTests: XCTestCase {
    func testExplainedKeepsIdentityAndAddsWhy() {
        let d = Diagnosis(title: "T", detail: "d", severity: .warning)
        let e = d.explained(evidence: ["A 1", "B 2"], impact: "Because.")
        XCTAssertEqual(e.id, d.id)
        XCTAssertEqual(e.evidence, ["A 1", "B 2"])
        XCTAssertEqual(e.impact, "Because.")
        // classified() must carry the explanation through.
        XCTAssertEqual(e.classified(tier: .note, area: .mac, action: nil).evidence, ["A 1", "B 2"])
    }

    func testOldPayloadsDecodeWithEmptyExplanation() throws {
        let json = #"{"id":"7E3F1C2A-1111-4222-8333-444455556666","title":"T","detail":"d","severity":1}"#
        let d = try JSONDecoder().decode(Diagnosis.self, from: Data(json.utf8))
        XCTAssertEqual(d.evidence, [])
        XCTAssertNil(d.impact)
    }

    func testOldIncidentsDecodeAndClassifyByTitle() throws {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        func incident(_ title: String) throws -> DiagnosisIncident {
            let json = #"{"id":"7E3F1C2A-1111-4222-8333-444455556666","title":"\#(title)","peakSeverity":1,"firstSeenAt":"2026-10-15T06:00:00Z","lastSeenAt":"2026-10-15T07:00:00Z"}"#
            return try d.decode(DiagnosisIncident.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try incident("Swap is holding old pages").tier, .note)
        XCTAssertEqual(try incident("Big processes that look unused").tier, .note)
        XCTAssertEqual(try incident("Docker is using significant resources").tier, .note)
        XCTAssertEqual(try incident("System is overloaded").tier, .problem)
        XCTAssertEqual(try incident("Your link to the router is stalling").area, .connection)
        XCTAssertEqual(try incident("System is overloaded").area, .mac)
    }

    func testTrackerRecordsTierAndAreaOnClosedIncidents() {
        var t = DiagnosisDurationTracker()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let d = Diagnosis(title: "X", detail: "", severity: .warning, tier: .note, area: .developer)
        _ = t.annotate([d], now: t0)
        let closed = t.annotate([], now: t0.addingTimeInterval(3600)).closedIncidents
        XCTAssertEqual(closed.first?.tier, .note)
        XCTAssertEqual(closed.first?.area, .developer)
    }

    func testDurationWords() {
        XCTAssertEqual(DurationText.words(seconds: 45), "45 s")
        XCTAssertEqual(DurationText.words(seconds: 999), "16 min")
        XCTAssertEqual(DurationText.words(seconds: 4200), "1 h 10 min")
        XCTAssertEqual(DurationText.words(seconds: 7200), "2 h")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ExplanationModelTests`
Expected: compile failure — `explained`, `evidence`, `tier` on incident, `DurationText` don't exist.

- [ ] **Step 3: Implement**

`Models.swift` — add to `Diagnosis`: stored `evidence: [String]`, `impact: String?`; public init gains `evidence: [String] = [], impact: String? = nil`; private memberwise init carries both; `classified` passes them through; add

```swift
public func explained(evidence: [String], impact: String?) -> Diagnosis {
    Diagnosis(id: id, title: title, detail: detail, severity: severity, culprits: culprits, kind: kind,
              subsumes: subsumes, tier: tier, area: area, action: action, evidence: evidence, impact: impact)
}
```
CodingKeys add `evidence, impact`; decode `decodeIfPresent([String].self) ?? []` and `decodeIfPresent(String.self)`.

`DiagnosisIncident.swift` — add `tier: Diagnosis.Tier`, `area: Diagnosis.Area` (init params with defaults `.problem`, `.mac`); custom `init(from:)` decoding all fields with `decodeIfPresent` for tier/area; when absent use

```swift
static func legacyTier(_ title: String) -> Diagnosis.Tier {
    [DiagnosisTitles.swapVolumeOnly, DiagnosisTitles.idleHogs, DiagnosisTitles.dockerStrain].contains(title) ? .note : .problem
}
static func legacyArea(_ title: String) -> Diagnosis.Area {
    if [ConnectionTitles.spikyWiFi, ConnectionTitles.pastRouter, ConnectionTitles.weakSignal, ConnectionTitles.outage, "Wi-Fi is spiky"].contains(title) { return .connection }
    if [DiagnosisTitles.dockerStrain].contains(title) { return .developer }
    return .mac
}
```
(Low disk warning was a note but can't be told from critical in old data — it stays `.problem`; it's rare and true.)

`DiagnosisDurationTracker.swift` — `State` gains `area`; closed incidents pass `tier: state.tier, area: state.area`.

`DurationText.swift`:
```swift
public enum DurationText {
    public static func words(seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        let h = s / 3600, m = s % 3600 / 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}
```

- [ ] **Step 4: Run tests** — `swift test` → all pass.
- [ ] **Step 5: Commit** — `git commit -am "Findings carry evidence and impact; incidents record tier and area"`

---

### Task 2: Evidence-accuracy helper and connection rule explanations

**Files:**
- Create: `Tests/WhirrCoreTests/EvidenceAccuracy.swift` (helper)
- Modify: `Sources/WhirrCore/Connection/ConnectionRules.swift`
- Test: `Tests/WhirrCoreTests/ConnectionRulesTests.swift`

**Interfaces:**
- Consumes: Task 1 `explained`.
- Produces: `EvidenceAccuracy.numbers(in: String) -> [Double]`, `EvidenceAccuracy.assertAllNumbers(_ d: Diagnosis, from inputs: [Double], file:line:)` — every number appearing in `d.evidence` must equal (±0.5) some value in `inputs`.

- [ ] **Step 1: Helper + failing tests**

```swift
import XCTest
@testable import WhirrCore

enum EvidenceAccuracy {
    static func numbers(in s: String) -> [Double] {
        let regex = try! NSRegularExpression(pattern: #"-?\d+(\.\d+)?"#)
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range, in: s).flatMap { Double(s[$0]) }
        }
    }

    static func assertAllNumbers(_ d: Diagnosis?, from inputs: [Double],
                                 file: StaticString = #filePath, line: UInt = #line) {
        guard let d else { return XCTFail("no diagnosis", file: file, line: line) }
        XCTAssertFalse(d.evidence.isEmpty, "\(d.title) has no evidence", file: file, line: line)
        for n in d.evidence.flatMap(numbers(in:)) {
            XCTAssertTrue(inputs.contains { abs($0 - n) <= 0.5 },
                          "\(d.title): \(n) not from inputs \(inputs)", file: file, line: line)
        }
    }
}
```

Add to `ConnectionRulesTests`:
```swift
func testConnectionFindingsExplainThemselvesFromTheirInputs() {
    let spiky = find(ConnectionTitles.spikyWiFi, snap(gateway: hop(spikes: 14, loss: 3)))
    EvidenceAccuracy.assertAllNumbers(spiky, from: [14, 3, 10])
    XCTAssertNotNil(spiky?.impact)
    let past = find(ConnectionTitles.pastRouter, snap(gateway: hop(spikes: 1), internet: hop(spikes: 9)))
    EvidenceAccuracy.assertAllNumbers(past, from: [1, 9, 0, 10])
    let weak = WiFiLink(rssi: -75, noise: -100, channel: 36, band: "5 GHz", widthMHz: 80, txRateMbps: 100, phyMode: "802.11ax")
    EvidenceAccuracy.assertAllNumbers(find(ConnectionTitles.weakSignal, snap(link: .some(weak))),
                                      from: [-75, 25, -72, 20, 5])
    let down = find(ConnectionTitles.outage, snap(outage: OutageRecord(start: Date(), cause: .unknown, networkId: "h")))
    XCTAssertTrue(down?.evidence.contains { $0.contains("can't tell") } ?? false)
}
```
(`hop(spikes:loss:)` helper exists in the file; add a `loss:` default if missing.)

- [ ] **Step 2: Run** — `swift test --filter ConnectionRulesTests` → FAIL (no evidence).
- [ ] **Step 3: Implement** — each rule returns `Diagnosis(...).explained(evidence:impact:)`:
  - Spiky: evidence `["\(g.spikes) stalls between your Mac and the router in the last 10 minutes", String(format: "%.0f%% of router checks lost", g.lossPercent)]`; impact `"Stalls make games, calls and streams stutter even when speed is fine."`
  - Past router: evidence `["Router link: \(g.spikes) stalls in 10 minutes (steady)", "Beyond the router: \(i.spikes) stalls, \(String(format: "%.0f", i.lossPercent))% lost"]`; impact as spiky.
  - Weak signal: evidence `["Signal \(link.rssi) dBm (weak below \(config.weakRssi) dBm)", "\(link.snr) dB above background noise (weak below \(config.weakSnr) dB)", "\(link.band)"]`; impact `"A weak signal can slow your connection and make it drop."`
  - Outage: evidence per cause — router: `"Router: no reply"`, `"Internet: no reply from 1.1.1.1 or 8.8.8.8"`; isp: `"Router: answering"`, internet line as before; wifi: `"This Mac isn't connected to Wi-Fi"`; unknown: `"Internet: no reply from 1.1.1.1 or 8.8.8.8"`, `"Your router doesn't answer Whirr's checks, so Whirr can't tell whether the router or the line is at fault"`; impact `nil` (the outage is self-evident).
- [ ] **Step 4: Run** — full suite passes.
- [ ] **Step 5: Commit** — `"Connection findings explain how Whirr knows and why it matters"`

---

### Task 3: Mac standalone rule explanations

**Files:**
- Modify: `Sources/WhirrCore/RulesEngine.swift` (MemoryPressureRule, SwapThrashingRule, ThermalThrottleRule, OverloadedSystemRule, RunawayProcessRule, HighDiskIORule, LowDiskSpaceRule, BackupHoggingRule)
- Test: `Tests/WhirrCoreTests/RulesEngineTests.swift`

**Interfaces:** Consumes Task 1 & 2 helpers. Produces explanations; the runaway detail no longer contains the command line or pid (those move into evidence).

- [ ] **Step 1: Failing tests** (add to RulesEngineTests):
```swift
func testMacFindingsExplainFromTheirInputs() {
    let pressure = engine.evaluate(snapshot: snapshot(used: 14 * .gb, available: 2 * .gb, pressure: .critical), processes: [])
    EvidenceAccuracy.assertAllNumbers(pressure.first { $0.title == DiagnosisTitles.memorySaturated }, from: [14, 2])
    let over = engine.evaluate(snapshot: snapshot(load: LoadAverage(oneMinute: 52.8, fiveMinute: 50, fifteenMinute: 40)), processes: [])
    let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
    EvidenceAccuracy.assertAllNumbers(over.first { $0.title == DiagnosisTitles.overloaded }, from: [52.8, cores, 52.8 / cores])
    let disk = engine.evaluate(snapshot: snapshot(diskFree: 25 * .gb, diskTotal: 1000 * .gb), processes: [])
    EvidenceAccuracy.assertAllNumbers(disk.first { $0.title == DiagnosisTitles.lowDisk }, from: [25, 97.5, 30, 10])
}

func testRunawayDetailHasNoPathOrPidButEvidenceDoes() {
    let p = process(pid: 29168, name: "node", cpu: 198, sustained: 20, commandLine: "/usr/local/bin/node server.js")
    let r = engine.evaluate(snapshot: snapshot(), processes: [p]).first { $0.title.hasSuffix(DiagnosisTitles.runawaySuffix) }
    XCTAssertFalse(r?.detail.contains("29168") ?? true)
    XCTAssertFalse(r?.detail.contains("/usr/local") ?? true)
    XCTAssertTrue(r?.evidence.contains { $0.contains("29168") } ?? false)
    XCTAssertTrue(r?.detail.contains("1 min") ?? false, r?.detail ?? "")  // 20 × 3 s
}
```
(Add `commandLine:` to the test `process` helper if missing.)
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** explanations:
  - Memory saturated/tight: evidence `["macOS memory pressure: high|elevated", "Memory in use: X GB", "Available: Y GB"]` (formatted `%.1f GB`); impact saturated: `"When memory runs out, macOS compresses and swaps it, and apps stall while they wait."`; tight: `"Opening more apps now can push the Mac into swapping."`
  - Actively paging: `["Reading ~N pages/s back from swap", "Swap: X GB", "Memory pressure: …"]`; impact `"Reading memory back from disk is far slower than RAM — that's the sluggishness."`
  - Swap volume (note): `["Swap: X GB", "Swap-ins: none right now"]`; impact nil.
  - Thermal: `["macOS thermal state: serious|critical"]`; impact `"The Mac slows its processor to cool down, so everything runs slower."`
  - Overloaded: `["Workload: L on C cores (R× capacity)"]` with L,C,R from the rule; impact `"With every core busy, apps and games wait their turn — that's the stutter."`
  - Runaway: detail becomes `"\(friendly) has been over 60% CPU for \(DurationText.words(seconds:)) — currently \(cpu)%."`; evidence `["CPU now: X%", "Above 60% for: <words>", "Process: <command line or name> (pid N)"]`; impact `"One process holding the processor leaves less for everything else."`
  - Disk busy: evidence `["<name> \(verb) <rate>"]`; impact `"Heavy disk use can slow apps that need the disk at the same time."`
  - Low disk: evidence `["Free: X GB of Y GB (P% full)", "Whirr warns below 30 GB and treats below 10 GB as serious"]` (numbers from config); impact `"macOS needs free space for swap, updates and caches."`
  - Backup: evidence `["<names>: <rate> disk, N% CPU"]`; impact `"A backup reading and writing the disk competes with your apps for it."`
- [ ] **Step 4: Run** — full suite. Update any existing assertion that read the old runaway detail ("for the last N seconds", "pid") to the new wording.
- [ ] **Step 5: Commit** — `"Mac findings explain how Whirr knows; paths and pids move into the why"`

---

### Task 4: Narrative explanations

**Files:**
- Modify: `Sources/WhirrCore/RulesEngine.swift` (DockerStrainNarrative, BackupChokingForegroundNarrative, DiskMemoryContentionNarrative, MemorySwapSpiralNarrative, ThermalThrottleAmplifierNarrative, WindowServerHogNarrative, SpotlightReindexNarrative, MemoryLeakNarrative, IdleMemoryHogsNarrative)
- Test: `Tests/WhirrCoreTests/RulesEngineTests.swift`

- [ ] **Step 1: Failing test** — one test per narrative that already has a fixture in RulesEngineTests: assert `!evidence.isEmpty` and `EvidenceAccuracy.assertAllNumbers(..., from: <fixture inputs>)`. Docker example:
```swift
func testDockerExplainsItsShare() {
    let r = engine.evaluate(snapshot: snapshot(used: 14 * .gb, available: 2 * .gb),
                            processes: [process(pid: 1, name: "com.docker.backend", mem: 1 * .gb),
                                        process(pid: 2, name: "com.apple.Virtualization.Virtua", mem: 8 * .gb)])
    let d = r.first { $0.title == DiagnosisTitles.dockerMajorLoad }
    EvidenceAccuracy.assertAllNumbers(d, from: [9, 0, 2, 56, 56.25, 0])
    XCTAssertNotNil(d?.impact)
}
```
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** — evidence lists restate the numbers each narrative already computes (memory GB, CPU %, shares, rates, idle minutes via `DurationText`, growth GB and window minutes); narratives that combine findings add one evidence line per combined signal ("Memory pressure: elevated", "Swap-ins: N/s"). Impacts:
  - Docker: `"Docker's virtual machine holds its memory and CPU even when containers are idle."`
  - Backup narrative: `"A backup and your apps compete for the same disk and memory."`
  - Contention: `"When memory runs short macOS swaps to the same drive, so both slow down."`
  - Spiral: `"Swapping makes apps slower, slower apps hold memory longer — it feeds itself until memory is freed."`
  - Thermal amplifier: `"Heavy work adds heat; heat makes the Mac slow its processor."`
  - WindowServer: `"WindowServer draws the screen; when it's busy, scrolling and animations stutter."`
  - Spotlight: `"Indexing uses disk and CPU until it finishes."`
  - Leak: `"Memory an app keeps growing is memory nothing else can use."`
  - Idle hogs (note): impact nil.
- [ ] **Step 4: Run** — full suite.
- [ ] **Step 5: Commit** — `"Narratives explain how Whirr knows and why it matters"`

---

### Task 5: Culprit owners and owner load

**Files:**
- Create: `Sources/WhirrCore/CulpritOwner.swift`
- Modify: `Sources/WhirrCore/SamplingPipeline.swift` (Result gains `ownerLoad`)
- Test: `Tests/WhirrCoreTests/CulpritOwnerTests.swift`

**Interfaces:**
- Produces:
```swift
public enum CulpritOwner {
    public static func owner(of culprit: String, dockerRunning: Bool) -> String
}
public struct OwnerLoad: Sendable, Equatable {
    public let cpuShare: [String: Double]     // owner → share of all CPU in use (0…1)
    public let memoryShare: [String: Double]  // owner → share of total RAM (0…1)
    public let seesAllProcesses: Bool
    public static let empty: OwnerLoad
    public static func compute(processes: [ProcessSample], totalRAM: UInt64,
                               describer: (ProcessSample) -> String, seesAllProcesses: Bool) -> OwnerLoad
}
```
`SamplingPipeline.Result.ownerLoad: OwnerLoad` (default `.empty`).

- [ ] **Step 1: Failing tests**
```swift
final class CulpritOwnerTests: XCTestCase {
    func testDockerFamily() {
        XCTAssertEqual(CulpritOwner.owner(of: "com.docker.backend", dockerRunning: true), "Docker")
        XCTAssertEqual(CulpritOwner.owner(of: "com.apple.Virtualization.Virtua", dockerRunning: true), "Docker")
        XCTAssertEqual(CulpritOwner.owner(of: "Virtualization VM (probably Docker)", dockerRunning: true), "Docker")
        XCTAssertEqual(CulpritOwner.owner(of: "com.apple.Virtualization.Virtua", dockerRunning: false), "com.apple.Virtualization.Virtua")
    }
    func testBackups() {
        XCTAssertEqual(CulpritOwner.owner(of: "bztransmit", dockerRunning: false), "Backblaze")
        XCTAssertEqual(CulpritOwner.owner(of: "backupd", dockerRunning: false), "Time Machine")
    }
    func testOtherNamesAreTheirOwnOwner() {
        XCTAssertEqual(CulpritOwner.owner(of: "Google Chrome", dockerRunning: false), "Google Chrome")
    }
    func testOwnerLoadShares() {
        func p(_ name: String, cpu: Double, gb: UInt64) -> ProcessSample {
            ProcessSample(pid: Int32.random(in: 2...99999), name: name, cpuPercent: cpu, memoryBytes: gb * 1_073_741_824)
        }
        let load = OwnerLoad.compute(processes: [p("com.docker.backend", cpu: 20, gb: 1),
                                                 p("com.apple.Virtualization.Virtua", cpu: 180, gb: 8),
                                                 p("Safari", cpu: 100, gb: 2)],
                                     totalRAM: 32 * 1_073_741_824, describer: { $0.name }, seesAllProcesses: true)
        XCTAssertEqual(load.cpuShare["Docker"] ?? 0, 200.0 / 300.0, accuracy: 0.001)
        XCTAssertEqual(load.memoryShare["Docker"] ?? 0, 9.0 / 32.0, accuracy: 0.001)
    }
}
```
(Use whichever `ProcessSample` initializer exists; its tolerant init has defaults for the remaining fields.)
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** — `owner(of:)`: `hasPrefix("com.docker.")` → "Docker"; contains "Virtualization" && dockerRunning → "Docker"; `hasPrefix("bz")` → "Backblaze"; `hasPrefix("backupd")` → "Time Machine"; else the name. `compute`: dockerRunning = any process named `com.docker.backend`; owner per process = `owner(of: name)` if that differs from the name, else `owner(of: describer(p))`; sum CPU and memory per owner; cpuShare = owner CPU / total CPU (0 if total 0); memoryShare = owner bytes / totalRAM. Pipeline: compute in both paths with `totalRAM = snapshot.memoryUsedBytes + memoryAvailableBytes`, `seesAllProcesses` true for daemon path, false in-process; pass into `Result`.
- [ ] **Step 4: Run** — full suite.
- [ ] **Step 5: Commit** — `"Culprit owners and per-owner load shares"`

---

### Task 6: StoryBuilder, stories in the verdict, per-story notifications

**Files:**
- Create: `Sources/WhirrCore/StoryBuilder.swift`
- Modify: `Sources/WhirrCore/VerdictSelector.swift`
- Modify: `Sources/Whirr/SystemMonitor.swift` (verdict + notifications use stories)
- Test: `Tests/WhirrCoreTests/StoryBuilderTests.swift`, update `VerdictSelectorTests.swift`

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces:
```swift
public struct Story: Sendable, Equatable, Identifiable {
    public let headline: DiagnosisContext
    public let members: [DiagnosisContext]      // includes headline first
    public let owner: String?
    public var id: String { headline.diagnosis.title }
    public var area: Diagnosis.Area { headline.diagnosis.area }
    public var action: SuggestedAction? { headline.diagnosis.action }
    public var because: String? { headline.diagnosis.evidence.first }
    public var evidence: [String]               // headline evidence + "<member title>: <member evidence.first>" for others
    public var impact: String? { headline.diagnosis.impact }
    public var phrase: String                   // StoryPhrases.phrase(for: headline title)
    public var durationSeconds: Int { headline.durationSeconds }
    public var isProblem: Bool { headline.diagnosis.tier == .problem }
}
public enum StoryBuilder {
    public static func build(_ contexts: [DiagnosisContext], load: OwnerLoad) -> [Story]
    public static func sentence(_ stories: [Story]) -> String?   // problem stories only; nil if none
}
public enum StoryPhrases { public static func phrase(for title: String) -> String }
```
`Verdict` gains `stories: [Story]` (gated problems, ranked), `pendingStories: [Story]`, `notes: [Story]`, `sentence: String?`; `headline`/`also` become computed from stories for existing callers (`headline = stories.first?.headline`). `VerdictSelector.select(_:isHidden:load:)` (load defaults to `.empty`). `VerdictSelector.shouldNotify(_ story: Story)`.

- [ ] **Step 1: Failing tests** (key cases)
```swift
final class StoryBuilderTests: XCTestCase {
    private func ctx(_ title: String, _ sev: Severity = .critical, culprits: [String] = [], tier: Diagnosis.Tier = .problem,
                     secs: Int = 600, evidence: [String] = ["e"]) -> DiagnosisContext {
        DiagnosisContext(diagnosis: Diagnosis(title: title, detail: "", severity: sev, culprits: culprits, tier: tier)
                            .explained(evidence: evidence, impact: "i"),
                         firstSeenAt: Date(), durationSeconds: secs, trend: .stable, peakSeverity: sev)
    }
    private let dockerHeavy = OwnerLoad(cpuShare: ["Docker": 0.42], memoryShare: ["Docker": 0.31], seesAllProcesses: true)

    func testSameOwnerMergesIntoOneStory() {
        let s = StoryBuilder.build([ctx(DiagnosisTitles.dockerMajorLoad, culprits: ["com.docker.backend"]),
                                    ctx("Virtualization VM (probably Docker) has been pegging CPU", culprits: ["Virtualization VM (probably Docker)"])],
                                   load: dockerHeavy)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].owner, "Docker")
        XCTAssertEqual(s[0].members.count, 2)
    }

    func testOverloadedJoinsOnlyTheMeasuredBiggestContributor() {
        let joined = StoryBuilder.build([ctx(DiagnosisTitles.dockerMajorLoad, culprits: ["com.docker.backend"]),
                                         ctx(DiagnosisTitles.overloaded)], load: dockerHeavy)
        XCTAssertEqual(joined.count, 1)
        let small = OwnerLoad(cpuShare: ["Docker": 0.2], memoryShare: ["Docker": 0.1], seesAllProcesses: true)
        XCTAssertEqual(StoryBuilder.build([ctx(DiagnosisTitles.dockerMajorLoad, culprits: ["com.docker.backend"]),
                                           ctx(DiagnosisTitles.overloaded)], load: small).count, 2)
        let blind = OwnerLoad(cpuShare: ["Docker": 0.9], memoryShare: [:], seesAllProcesses: false)
        XCTAssertEqual(StoryBuilder.build([ctx(DiagnosisTitles.dockerMajorLoad, culprits: ["com.docker.backend"]),
                                           ctx(DiagnosisTitles.overloaded)], load: blind).count, 2)
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

    func testSentenceCombinesUpToThreeProblems() {
        let stories = StoryBuilder.build([ctx(DiagnosisTitles.overloaded), ctx(ConnectionTitles.spikyWiFi, .warning),
                                          ctx(DiagnosisTitles.lowDisk, .critical), ctx(DiagnosisTitles.thermalWarning, .warning)],
                                         load: .empty)
        let s = StoryBuilder.sentence(stories) ?? ""
        XCTAssertTrue(s.hasPrefix("Your Mac is overloaded"), s)
        XCTAssertTrue(s.contains("and 1 more"), s)
        XCTAssertTrue(s.hasSuffix("."), s)
    }

    func testNotesNeverMakeASentence() {
        XCTAssertNil(StoryBuilder.sentence(StoryBuilder.build([ctx(DiagnosisTitles.swapVolumeOnly, tier: .note)], load: .empty)))
    }

    func testStoryEvidenceIncludesMembers() {
        let s = StoryBuilder.build([ctx("A", culprits: ["X"], evidence: ["a1"]), ctx("B", .warning, culprits: ["X"], evidence: ["b1"])], load: .empty)
        XCTAssertEqual(s[0].evidence, ["a1", "B: b1"])
    }
}
```
VerdictSelectorTests: hidden-member case (Review Focus 2) — a story whose headline title is hidden but another member isn't keeps the visible member as headline; all hidden → story gone.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement**
  - Owners: for each context, `owner = culprits.first.map { CulpritOwner.owner(of: $0, dockerRunning: load.cpuShare["Docker"] != nil || load.memoryShare["Docker"] != nil) }`.
  - Group contexts with a non-nil owner by owner (stable order).
  - System-wide titles: `[overloaded, thermalWarning, thermalCritical]` join the owner story with the largest `cpuShare` if `load.seesAllProcesses && share >= 0.4`; `[memorySaturated, memoryTight, swapActivelyPaging]` join the owner story with the largest `memoryShare` if `>= 0.25`. Otherwise their own story.
  - Remaining contexts (no owner) are single-member stories.
  - Headline: sort members by (problem tier first, `VerdictSelector.isMoreImportant`).
  - Stories ranked by `VerdictSelector.isMoreImportant` on headlines.
  - `StoryPhrases.phrase`: table — overloaded "your Mac is overloaded"; memorySaturated "memory is saturated"; memoryTight "memory is getting tight"; swapActivelyPaging "your Mac is paging memory to disk"; thermal* "your Mac is slowing down from heat"; lowDisk "your disk is nearly full"; diskBusy "the disk is very busy"; dockerMajorLoad "Docker is weighing your Mac down"; backup titles "a backup is competing with your apps"; spikyWiFi "your link to the router is stalling"; pastRouter "the connection beyond your router is stalling"; weakSignal "your Wi-Fi signal is weak"; outage "the internet is down"; runaway suffix → "\(name) is stuck at high CPU"; leak suffix → "\(name)'s memory keeps growing"; default lowercased-first title.
  - `sentence`: problem stories; phrases joined "A", "A and B", "A, B, and C", +" and N more" when > 3; capitalize first letter; end with ".".
  - Verdict/VerdictSelector: hidden filtering happens on members first (drop hidden members, rebuild), then gating on the story headline's duration; `areaSeverity` from gated story headlines; `shouldNotify(story)` = problem, critical headline, ≥ 300 s, action != nil.
  - SystemMonitor: `verdict = VerdictSelector.select(result.diagnosisContexts, isHidden: isHidden, load: result.ownerLoad)`; notifications: `notifiable = verdict.stories.filter(VerdictSelector.shouldNotify).map(\.headline.diagnosis)`.
- [ ] **Step 4: Run** — full suite; fix VerdictSelectorTests construction sites for the new `Verdict` init.
- [ ] **Step 5: Commit** — `"Stories: findings with one cause become one story with one sentence and one action"`

---

### Task 7: HistoryDigest

**Files:**
- Create: `Sources/WhirrCore/HistoryDigest.swift`
- Modify: `Sources/WhirrCore/DiagnosisIncident.swift` (IncidentLog unchanged API)
- Test: `Tests/WhirrCoreTests/HistoryDigestTests.swift`

**Interfaces:**
```swift
public struct HistoryEvent: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case mac, connection, wifi }
    public let id: String
    public let at: Date
    public let kind: Kind
    public let text: String
    public let durationSeconds: Int?
}
public struct HistoryDay: Sendable, Equatable, Identifiable {
    public let day: Date                 // start of local day
    public var id: Date { day }
    public let summary: String           // "6 outages · 6 min · Mac overloaded 2 h 10 min"
    public let events: [HistoryEvent]    // newest first
    public let hasOlderMethodOutages: Bool
}
public struct HistoryDigest: Sendable, Equatable {
    public let weekSentence: String
    public let days: [HistoryDay]        // newest first
    public let patterns: [String]
    public static func compute(incidents: [DiagnosisIncident], outages: [OutageRecord], changes: [ChannelChange],
                               networkId: String?, now: Date, calendar: Calendar = .current) -> HistoryDigest
}
```

- [ ] **Step 1: Failing tests** — cover: quiet week sentence; outages total & minutes; night clause present only when N ≥ 3 and ≥ ⅔ in 21:00–03:00 and only reliable outages counted for it; "mostly while Docker was running" only when Docker owns ≥ ⅔ of the top headline's time; notes and the outage incident title excluded; old-method outages flag `hasOlderMethodOutages`; days newest first; events newest first; patterns ≥ 3 of 7 days; other networks' outages excluded. Example:
```swift
func testNightClauseOnlyWithEnoughReliableOutages() {
    let night = (0..<3).map { OutageRecord(start: at(day: -$0, hour: 23), end: at(day: -$0, hour: 23, minute: 1), cause: .isp, networkId: "h") }
    XCTAssertTrue(digest(outages: night).weekSentence.contains("3 of them between 9 pm and 3 am"))
    let old = night.map { OutageRecord(start: $0.start, end: $0.end, cause: $0.cause, networkId: "h", causeMethod: 1) }
    XCTAssertFalse(digest(outages: old).weekSentence.contains("between 9 pm"))
    XCTAssertFalse(digest(outages: Array(night.prefix(2))).weekSentence.contains("between 9 pm"))
}
```
(`at(day:hour:minute:)` and `digest(...)` are local helpers in the test using a fixed New York calendar and `now` = 2026-10-17 15:00.)
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** per spec §3. Mac events: incidents with `tier == .problem`, `area != .connection` or connection titles other than `ConnectionTitles.outage`; text = `StoryPhrases.phrase(for: title)` capitalized, plus " — mostly <owner>" when a culprit owner exists; outage events text = `OutageReport.cause` without the older-method suffix (`OutageCause.summary`-style short text: "Down beyond the router", "Router stopped responding", "Wi-Fi disconnected", "Connection down (cause unclear)"); channel change text = `ChannelChange.description`. Day summary pieces joined " · ": "N outage(s)", total outage time via `DurationText`, "Mac <phrase> T" for the longest Mac problem headline that day, "Wi-Fi channel changed" if any. Week sentence: "This week: " + clauses joined; quiet fallback.
- [ ] **Step 4: Run** — full suite.
- [ ] **Step 5: Commit** — `"History digest: week sentence, day groups and patterns from countable facts"`

---

### Task 8: History store robustness

**Files:**
- Modify: `Sources/WhirrCore/Connection/ConnectionHistoryStore.swift`, `Sources/WhirrCore/Connection/ConnectionMonitor.swift`
- Test: `Tests/WhirrCoreTests/ConnectionHistoryStoreTests.swift`, `ConnectionMonitorTests.swift`

- [ ] **Step 1: Failing tests**
```swift
func testAppendAfterATornLineStartsOnAFreshLine() throws {
    let store = ConnectionHistoryStore(directory: dir)
    store.append(agg(minute: 0))
    let url = dir.appendingPathComponent("connection-history.jsonl")
    let h = try FileHandle(forWritingTo: url); h.seekToEndOfFile(); h.write(Data("{\"torn".utf8)); try h.close()
    store.append(agg(minute: 1))
    XCTAssertEqual(store.aggregates(since: .distantPast).count, 2)
}
```
Monitor: `testPurgesOncePerDayWhileRunning` — drive `pingRound` across a day boundary (injectable clock already: rounds take `at:`) and assert aggregates older than retention vanish without restarting.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** — `append`: if the file's last byte isn't `\n`, prepend `\n`; use `try handle.write(contentsOf:)` inside `do/catch` (ignore failure). Monitor: track `lastPurgeDay`; in `pingRound`, when the local day of `now` differs, call `store.purge(olderThan: now - retention)`.
- [ ] **Step 4: Run** — full suite.
- [ ] **Step 5: Commit** — `"History store: daily purge, survives torn lines and full disks"`

---

### Task 9: Split SystemMonitor

**Files:**
- Create: `Sources/Whirr/ConnectionController.swift`, `Sources/Whirr/Navigation.swift`
- Modify: `Sources/Whirr/SystemMonitor.swift` and every view referencing moved members

**Interfaces:**
- `@MainActor @Observable final class ConnectionController` — owns `connection`, `connectionTestPhase`, `latestConnectionTest`, `gatewayIP`, `store`, the `ConnectionMonitor` actor and test runner; `start()`, `snapshot() async -> ConnectionSnapshot`, `runTest()`.
- `@MainActor @Observable final class Navigation` — `selectedSection`, `presentedHowTo`, `pendingConnectionTest`, `focusedStoryID: String?`, `openStory(_ story: Story)` (selects the story's area and sets focus).
- `SystemMonitor` exposes `let connection: ConnectionController`, `let nav: Navigation`; keeps sampling, stories, notifications, Docker, Harbr.

- [ ] **Step 1:** Move code verbatim; compile-driven rename at call sites (`monitor.connection` → `monitor.connection.connection` is awkward — name the controller property `net` and keep `monitor.net.connection`, `monitor.net.runTest()`, `monitor.nav.selectedSection`).
- [ ] **Step 2:** `swift build` → fix all call sites until clean; `swift test` → all pass (no core changes).
- [ ] **Step 3:** Build the app (`./build.sh`), launch, confirm the window, sidebar navigation and "Check my connection" still work.
- [ ] **Step 4: Commit** — `"Split SystemMonitor: ConnectionController and Navigation"`

---

### Task 10: Story card, Why panel, dropdown and Overview

**Files:**
- Create: `Sources/Whirr/Sections/StoryCard.swift`
- Modify: `Sources/Whirr/MenuPopoverView.swift`, `Sources/Whirr/Sections/OverviewSection.swift`

**Interfaces:** `StoryCard(monitor:story:prominent:)`, `WhyPanel(story:)`, `AnswerCard(monitor:area:)` (area nil = whole Mac+connection).

- [ ] **Step 1: Implement**
  - `WhyPanel`: two blocks — "How Whirr knows" (evidence as bullet list, `textSelection`), "Why it matters" (impact) — omitted when both empty.
  - `StoryCard`: symbol + headline title (or phrase capitalized for prominent), `because` line beneath, "Why?" toggle button (hidden if evidence and impact both empty) that expands `WhyPanel`, action button (confirmation as today), ⋯ menu (snooze/mute applies to every member title), duration via `DurationText`. Expanded automatically when `monitor.nav.focusedStoryID == story.id`.
  - `AnswerCard`: states — not sampled ("Checking…"), problems (sentence + because of top story + action + Why), pending ("Keeping an eye on something — <phrase>."), calm (green, "All good. Mac and connection steady." / per area "All good on your Mac." / "Your connection is steady.").
  - Dropdown: dot + `verdict.sentence` (or calm/pending/checking text), because line, primary action, then one "Also:" line per remaining story (phrase capitalized + because, tap → `nav.openStory` + open window), footer "Open Whirr → see why" opens the window on the top story.
  - Overview: `AnswerCard(area: nil)`; remaining stories as single-line rows (because + chevron → `openStory`); Mac/Connection tiles (Mac tile line = top Mac story phrase or "Steady", plus memory pressure word; Connection tile = `ConnectionText.summary`).
- [ ] **Step 2:** `./build.sh`, install, screenshot dropdown and Overview in the current (problem) state; check the sentence matches the stories, no "Working fine" above a problem.
- [ ] **Step 3: Commit** — `"Answer-first dropdown and Overview with a Why behind every story"`

---

### Task 11: Short section pages with fold-open detail

**Files:**
- Create: `Sources/Whirr/Sections/FoldRow.swift`
- Modify: `Sources/Whirr/Sections/MacSection.swift`, `ConnectionSection.swift`, `DeveloperSection.swift`, `FindingCard.swift` (FindingsList renders stories)

- [ ] **Step 1: Implement**
  - `FoldRow(title:subtitle:key:content:)` — `DisclosureGroup` whose expanded state is `@AppStorage("fold.\(key)")`.
  - `FindingsList(area:)` renders `StoryCard`s for that area's stories (gated + pending + notes, notes last and grey), quieted group unchanged.
  - Mac: `AnswerCard(area: .mac)`; stories; three facts (memory pressure, workload, free disk, each with ⓘ); folds: "What's using your Mac" (process rows), "All measurements" (current facts grid incl. memory in use, swap, heat), "Background helper".
  - Connection: `AnswerCard(area: .connection)`; stories; three facts (signal word + dB, router link `HopHealth` word, internet link word); folds: "Wi-Fi details" (LinkCard facts), "Today", "Check my connection" (button + report card), "How each channel has done", "Channel changes", "Outages".
  - Developer: `AnswerCard(area: .developer)`; stories; three facts (containers running, Docker memory, dev servers up); folds: "Containers", "Dev servers".
  - Replace every `MenuFormat.duration` use in views with `DurationText.words`.
- [ ] **Step 2:** Build, install, screenshot Mac, Connection, Developer; verify no path/pid outside Why, durations in words, fold state persists across relaunch.
- [ ] **Step 3: Commit** — `"Section pages: answer, findings, three facts, everything else folded"`

---

### Task 12: History page rebuilt; retire Insights and the 30-minute bar

**Files:**
- Modify: `Sources/Whirr/Sections/HistorySectionView.swift`
- Delete: `Sources/Whirr/InsightsView.swift`, `Sources/Whirr/HistorySection.swift`

- [ ] **Step 1: Implement** — load incidents (`incidentLog.incidents(from: now-7d, to: now)` plus currently open problem stories as ongoing incidents), outages and aggregates off the main actor; compute `HistoryDigest`; render: week sentence card; `ForEach(days)` — today expanded, others `DisclosureGroup` with the day summary as label; event rows (time, chip, text, duration via `DurationText`); one "Causes before Oct 17 came from an older, less reliable method." line per day with `hasOlderMethodOutages`; folds "Connection tests" (existing TestSummary list) and "Patterns" (digest.patterns or "No repeating problems this week."). Remove references to `trendHistory` view and `InsightsView`; keep `trendHistory` data only if another view uses it, else remove the property.
- [ ] **Step 2:** `swift build`, `swift test`, build/install, screenshot History.
- [ ] **Step 3: Commit** — `"History: week sentence over a compact day-grouped timeline"`

---

### Task 13: README, final verification

**Files:** `README.md`

- [ ] **Step 1:** Update "Using Whirr": dropdown answer + Why, Overview, section pages with folds, History description; remove Insights mentions.
- [ ] **Step 2:** Full `swift test`; build, install; screenshots of dropdown, Overview, Mac, Connection, History, Learn.
- [ ] **Step 3: Commit** — `"README: answer-first design"`
