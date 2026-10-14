# Whirr Window + Connection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Whirr's overloaded menu bar dropdown with a sidebar window app, add passive + on-demand connection monitoring, and stop the status icon crying wolf.

**Architecture:** `WhirrCore` gains a findings model (tier/area/action) applied as a post-pass over existing rules, a `Connection/` subsystem (pinger, Wi-Fi reader, stats, outage detector, history store, channel comparison, test runner, report card) whose `ConnectionSnapshot` feeds new rules through `CoreContext`. The `Whirr` app gets a `Window` scene with `NavigationSplitView`, reusing existing row/section views, and a slim popover.

**Tech Stack:** Swift 5.10 tools / Swift 6.3 compiler, SwiftUI (macOS 14+), CoreWLAN, Network.framework (`NWPathMonitor`), Darwin ICMP sockets, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-14-whirr-window-and-connection-design.md`

## Global Constraints

- macOS 14+ deployment (`platforms: [.macOS(.v14)]`). No new SPM dependencies.
- No shelling out for sampling (`top`/`ps`); the only subprocess allowed is the user-triggered `/usr/bin/networkQuality` in the full test.
- Passive pings: every 2 s, gateway + `1.1.1.1` (fallback `8.8.8.8`), 1 s timeout, unprivileged ICMP. Never scan Wi-Fi in the background.
- All on-disk additions under `~/Library/Application Support/Whirr/`. Connection history retention 30 days.
- All new `Codable` fields decode with `decodeIfPresent ?? default` (wire-compat pattern already used in `Models.swift`).
- User-facing copy: plain English, no jargon without a gloss ("jitter" → "how uneven your connection is").
- Notes never color the menu bar icon or notify. Problems color it only after 2 min; notify only when critical, ≥ 5 min, have an action, not snoozed/muted.

## Review Focus

1. **Laptop sleep/wake** — pings across sleep must not register an outage. Test: `OutageDetector` given a gap in sample timestamps > 30 s resets state instead of counting misses (Task 5).
2. **Network switch (home → hotspot)** — stats from different gateways must not mix. Test: `ConnectionStats` window resets when `networkId` changes (Task 5) and `ChannelComparison` filters by networkId (Task 7).
3. **Router that drops ICMP** — must not produce a permanent "router down" outage. Test: `OutageDetector` with `gatewayPingable == false` attributes only by internet hop (Task 5).
4. **Old daemon payload with missing keys** — must decode. Test: May-format process JSON decodes (Task 1).
5. **Diagnosis title flapping between severities** — headline must not jump between two problems every tick. Test: `VerdictSelector` ties broken by duration, deterministic (Task 3).

---

## File map

**WhirrCore (new)**
- `Findings.swift` — `Diagnosis.Tier`, `Diagnosis.Area`, `SuggestedAction`, `FindingClassifier` (post-pass re-tiering).
- `VerdictSelector.swift` — Overview headline selection.
- `Connection/ConnectionModels.swift` — `PingSample`, `Hop`, `WiFiLink`, `HopStats`, `ConnectionSnapshot`, `OutageRecord`, `MinuteAggregate`.
- `Connection/Pinger.swift` — `Pinging` protocol + `ICMPPinger`.
- `Connection/WiFiReader.swift` — `WiFiReading` protocol + `CoreWLANReader`.
- `Connection/GatewayResolver.swift` — default gateway IP + MAC.
- `Connection/ConnectionStats.swift` — rolling per-hop stats.
- `Connection/OutageDetector.swift`.
- `Connection/ConnectionHistoryStore.swift` — minute aggregates jsonl + outages.json + tests.json.
- `Connection/ConnectionMonitor.swift` — actor tying pinger/reader/stats/outages/history together.
- `Connection/ConnectionRules.swift` — 4 rules + config.
- `Connection/ChannelComparison.swift`.
- `Connection/ConnectionTestRunner.swift` + `Connection/ConnectionReportCard.swift`.

**WhirrCore (modified)** `Models.swift` (tolerant ProcessSample decode, Diagnosis fields), `RulesEngine.swift` (connection in CoreContext, classifier post-pass), `RulesConfig.swift` (connection config), `SamplingPipeline.swift` (daemonStatus, connection passthrough), `SnoozeStore.swift` (mute).

**Whirr app (new)** `MainWindow.swift`, `Sections/OverviewSection.swift`, `Sections/MacSection.swift`, `Sections/ConnectionSection.swift`, `Sections/HistorySectionView.swift`, `Sections/DeveloperSection.swift`, `ActionHandler.swift`, `HowToSheet.swift`, `MenuPopoverView.swift`.
**Whirr app (modified)** `WhirrApp.swift`, `SystemMonitor.swift`, `NotificationService.swift`, `SettingsView.swift`, `OnboardingView.swift`.
**Probe** `Sources/WhirrProbe/main.swift` (`--network`).

---

### Task 1: Tolerant ProcessSample decode + daemon status

**Files:** Modify `Sources/WhirrCore/Models.swift`, `Sources/WhirrCore/SamplingPipeline.swift`; Test `Tests/WhirrCoreTests/SamplingPipelineTests.swift`, new `Tests/WhirrCoreTests/ProcessSampleDecodeTests.swift`.

**Produces:** `public enum DaemonStatus: Sendable { case fresh, stale, undecodable, absent }`; `SamplingPipeline.Result.daemonStatus: DaemonStatus`.

- [ ] Step 1: Failing test — May-format JSON decodes:
```swift
func testDecodesPayloadMissingNewerFields() throws {
    let json = #"{"pid":1,"name":"bzserv","cpuPercent":3.5,"memoryBytes":100,"diskReadBytesPerSec":0,"diskWriteBytesPerSec":0,"commandLine":null,"sustainedHighCpuSamples":0}"#
    let p = try JSONDecoder().decode(ProcessSample.self, from: Data(json.utf8))
    XCTAssertEqual(p.sustainedIdleSamples, 0)
    XCTAssertNil(p.memoryDelta10MinBytes)
    XCTAssertNil(p.parentPid)
}
```
- [ ] Step 2: `swift test --filter ProcessSampleDecodeTests` → FAIL (keyNotFound sustainedIdleSamples).
- [ ] Step 3: Add `CodingKeys` + `init(from:)` to `ProcessSample`: required `pid, name, cpuPercent, memoryBytes`; everything else `decodeIfPresent ?? default` (0 / nil). Keep synthesized `encode` (explicit `CodingKeys` keeps it).
- [ ] Step 4: Test passes.
- [ ] Step 5: Failing test in `SamplingPipelineTests`: write a garbage `snapshot.json` to a temp path → `tick().daemonStatus == .undecodable` and `source == .inProcess`; missing file → `.absent`; valid but old `capturedAt` → `.stale`; valid fresh → `.fresh`.
- [ ] Step 6: Implement: `readDaemonSnapshot` returns `(Result?, DaemonStatus)`; thread status into `Result` (new init param with default `.absent`).
- [ ] Step 7: All tests pass; commit `Tolerant ProcessSample decode; surface daemon status`.

### Task 2: Findings model + classifier + mute

**Files:** Create `Sources/WhirrCore/Findings.swift`; Modify `Models.swift` (Diagnosis), `RulesEngine.swift` (post-pass), `SnoozeStore.swift`; Tests `FindingsTests.swift`, `SnoozeStoreTests.swift`.

**Produces:**
```swift
extension Diagnosis {
  public enum Tier: String, Codable, Sendable { case problem, note }
  public enum Area: String, Codable, Sendable { case mac, connection, developer }
}
public struct SuggestedAction: Hashable, Codable, Sendable {
  public enum Kind: Hashable, Codable, Sendable {
    case quitApp(pid: Int32), stopDocker, openURL(URL), openSection(Diagnosis.Area),
         runConnectionTest, showHowTo(HowTo)
  }
  public enum HowTo: String, Hashable, Codable, Sendable {
    case changeWiFiChannel, talkToISP, improveSignal, freeDiskSpace, reinstallSampler, routerOutage, ispOutage
  }
  public let label: String; public let kind: Kind
}
// Diagnosis gains: tier (default .problem), area (default .mac), action (default nil)
// + func classified(tier:area:action:) -> Diagnosis   (preserves id)
public enum FindingClassifier { public static func classify(_ ds: [Diagnosis]) -> [Diagnosis] }
// SnoozeStore: mute(_ title), unmute(_ title), isMuted(_ title) -> Bool, mutedTitles: [String]
```

- [ ] Step 1: Failing tests (`FindingsTests`):
  - swap-volume-only → `.note`; disk-nearly-full warning → note, critical → problem with `.showHowTo(.freeDiskSpace)`; "Big processes that look unused" → note.
  - Docker diagnosis alone → `.developer` + `.note`; Docker + "System is overloaded" present → `.mac` + `.problem` + action `.stopDocker`.
  - Runaway process diagnosis with culprit → action `.quitApp` is NOT set (no pid in Diagnosis) — stays nil; `classify` preserves `id`.
  - Old daemon Diagnosis JSON without tier/area decodes as `.problem` / `.mac`.
- [ ] Step 2: Run → FAIL.
- [ ] Step 3: Implement fields (Codable additive), `classified(...)` via a private memberwise init that takes `id`, and `FindingClassifier` mapping by `DiagnosisTitles` constants (add `dockerStrain = "Docker is using significant resources"`, `idleHogs = "Big processes that look unused"`, `lowDisk = "Disk is nearly full"`, `overloaded = "System is overloaded"` constants and use them in the rules). Strain set = overloaded, memorySaturated, swapActivelyPaging, thermalWarning, thermalCritical. Call `FindingClassifier.classify` at the end of `RulesEngine.evaluate`.
- [ ] Step 4: Mute tests in `SnoozeStoreTests` (mute persists across new store instance with same UserDefaults suite; unmute removes; mutes never expire). Implement with key `preferences.mutedDiagnoses.v1` storing `[String]`.
- [ ] Step 5: Full suite passes (existing rule tests compare titles/severity; must still pass). Commit `Findings model: problem/note tiers, areas, actions, mute`.

### Task 3: VerdictSelector + gated icon + gated notifications

**Files:** Create `Sources/WhirrCore/VerdictSelector.swift`; Modify `Sources/Whirr/SystemMonitor.swift`, `Sources/Whirr/NotificationService.swift`; Test `VerdictSelectorTests.swift`.

**Produces:**
```swift
public struct Verdict: Sendable, Equatable {
  public let headline: DiagnosisContext?      // nil = all clear
  public let also: [DiagnosisContext]
  public let areaSeverity: [Diagnosis.Area: Severity]  // gated problems only
  public var worst: Severity
}
public enum VerdictSelector {
  public static let iconGateSeconds = 120
  public static let notifyGateSeconds = 300
  public static func select(_ contexts: [DiagnosisContext], isHidden: (String) -> Bool) -> Verdict
  public static func shouldNotify(_ c: DiagnosisContext) -> Bool  // critical && ≥300s && action != nil
}
```
- [ ] Step 1: Failing tests: notes never headline; problem at 60 s not headline, at 130 s is; two criticals → longer duration wins; equal duration → narrative wins, then title order (deterministic); hidden (snoozed/muted) excluded; `areaSeverity` per area; `shouldNotify` matrix.
- [ ] Step 2: FAIL → Step 3 implement → Step 4 PASS.
- [ ] Step 5: `SystemMonitor`: add `var verdict: Verdict`; `worstSeverity` → `verdict.worst`; `isHidden = snoozed || muted`. `NotificationService.process` takes contexts and filters with `shouldNotify` before the edge tracker.
- [ ] Step 6: `swift build` + tests pass. Commit `Verdict selection; gate icon and notifications`.

### Task 4: Connection models, pinger, Wi-Fi reader, gateway resolver

**Files:** Create `Connection/ConnectionModels.swift`, `Pinger.swift`, `WiFiReader.swift`, `GatewayResolver.swift`; Modify `Package.swift` (link `CoreWLAN` to WhirrCore via `linkerSettings: [.linkedFramework("CoreWLAN")]`).

**Produces:**
```swift
public enum Hop: String, Codable, Sendable, CaseIterable { case gateway, internet }
public struct PingSample: Codable, Sendable, Equatable { public let at: Date; public let hop: Hop; public let rttMs: Double? } // nil = timeout
public struct WiFiLink: Codable, Sendable, Equatable { rssi: Int; noise: Int; channel: Int; band: String /* "2.4 GHz"/"5 GHz"/"6 GHz" */; widthMHz: Int; txRateMbps: Double; phyMode: String; var snr: Int { rssi - noise } }
public struct NeighborCount: Codable, Sendable, Equatable { public let channel: Int; public let band: String; public let count: Int }
public protocol Pinging: Sendable { func ping(_ host: String, timeout: TimeInterval) async -> Double? }
public protocol WiFiReading: Sendable { func currentLink() -> WiFiLink?; func scanNeighbors() -> [NeighborCount] }
public struct GatewayInfo: Sendable, Equatable { public let ip: String; public let mac: String? ; public var networkId: String { mac ?? ip } }
public enum GatewayResolver { public static func current() -> GatewayInfo? }
```
- [ ] Step 1: `ICMPPinger`: `socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)`, build echo request (type 8, id = random, seq increment, checksum), `sendto`, `poll` with timeout, `recvfrom` loop matching seq (kernel rewrites id on DGRAM sockets — match on seq only), return ms. Run blocking work on a detached task.
- [ ] Step 2: `CoreWLANReader.currentLink()` from `CWWiFiClient.shared().interface()`; nil if no interface or `powerOn() == false` or `wlanChannel() == nil`. `scanNeighbors()` → `scanForNetworks(withSSID: nil)` grouped by channel number+band, excluding... (include all).
- [ ] Step 3: `GatewayResolver`: `SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4")["Router"]` for IP; MAC via `sysctl` `NET_RT_FLAGS`/`RTF_LLINFO` ARP table lookup for that IP (format `aa:bb:..`).
- [ ] Step 4: Test `ConnectionModelsTests`: `WiFiLink.snr`, `GatewayInfo.networkId` falls back to ip. Live smoke check through probe in Task 7.
- [ ] Step 5: Build passes; commit `Connection primitives: ICMP pinger, CoreWLAN reader, gateway resolver`.

### Task 5: ConnectionStats + OutageDetector

**Files:** Create `Connection/ConnectionStats.swift`, `Connection/OutageDetector.swift`; Tests `ConnectionStatsTests.swift`, `OutageDetectorTests.swift`.

**Produces:**
```swift
public struct HopStats: Codable, Sendable, Equatable { count, medianMs: Double?, p95Ms: Double?, jitterMs: Double?, lossPercent: Double, spikes: Int }
public struct ConnectionStats: Sendable {
  public init(retention: TimeInterval = 3600)
  public mutating func record(_ s: PingSample, networkId: String)   // resets when networkId changes
  public func stats(hop: Hop, window: TimeInterval, now: Date) -> HopStats
  public static func isSpike(_ rtt: Double?, median: Double) -> Bool  // nil → true; rtt > max(median*3, median+50)
}
public enum OutageCause: String, Codable, Sendable { case router, isp, wifiDisconnected }
public struct OutageRecord: Codable, Sendable, Equatable, Identifiable { id: UUID; start: Date; end: Date?; cause: OutageCause; networkId: String }
public struct OutageDetector: Sendable {
  public static let minDuration: TimeInterval = 10
  public static let sleepGap: TimeInterval = 30
  public mutating func observe(gatewayOK: Bool?, internetOK: Bool, wifiAssociated: Bool, at: Date, networkId: String) -> (opened: OutageRecord?, closed: OutageRecord?)
  public var current: OutageRecord? { get }
}
```
`gatewayOK == nil` means gateway not pingable (internet-only mode).
- [ ] Step 1: Stats tests: median/p95 of known samples; loss% with timeouts; spike detection (median 5 ms: 60 ms is spike, 40 ms not; median 30: 95 spike, 85 not); window filtering; networkId change clears samples (**Review Focus 2**).
- [ ] Step 2: Outage tests: both down 12 s → opened `.router` at first failure timestamp; gateway up + internet down 12 s → `.isp`; down 8 s then recover → nothing; wifi not associated → `.wifiDisconnected`; recovery closes with end; sample gap > 30 s resets pending state with no outage (**Review Focus 1**); `gatewayOK == nil` + internet down → `.isp` never `.router` (**Review Focus 3**).
- [ ] Step 3: FAIL → implement → PASS. Commit `Rolling connection stats and outage detection`.

### Task 6: History store + ConnectionMonitor actor

**Files:** Create `Connection/ConnectionHistoryStore.swift`, `Connection/ConnectionMonitor.swift`; Tests `ConnectionHistoryStoreTests.swift`, `ConnectionMonitorTests.swift`.

**Produces:**
```swift
public struct MinuteAggregate: Codable, Sendable, Equatable { minute: Date; networkId: String; gateway: HopStats; internet: HopStats; channel: Int?; band: String?; rssi: Int?; noise: Int? }
public final class ConnectionHistoryStore: @unchecked Sendable {   // NSLock-guarded, file IO
  public init(directory: URL = default AppSupport/Whirr)
  public func append(_ m: MinuteAggregate); public func aggregates(since: Date) -> [MinuteAggregate]
  public func purge(olderThan: Date)
  public func appendOutage(_ o: OutageRecord) / updateOutage / outages() -> [OutageRecord]
  public func saveTest(_ r: ConnectionTestResult) / tests() -> [ConnectionTestResult]  (last 50)
}
public struct ConnectionSnapshot: Sendable, Equatable {
  link: WiFiLink?; isWired: Bool; gatewayPingable: Bool; networkId: String?;
  gateway1m, internet1m, gateway10m, internet10m: HopStats; currentOutage: OutageRecord?; paused: Bool
  public static let empty
}
public actor ConnectionMonitor {
  public init(pinger: Pinging = ICMPPinger(), wifi: WiFiReading = CoreWLANReader(), store: ConnectionHistoryStore = .init(), gateway: @Sendable @escaping () -> GatewayInfo? = GatewayResolver.current, clock: ...)
  public func start(); public func stop(); public func setPaused(_ p: Bool)
  public func snapshot() -> ConnectionSnapshot
  public func pingRound(at: Date) async      // one 2 s iteration; internal but exposed for tests
}
```
- [ ] Step 1: Store tests with temp dir: append/read aggregates; purge; outages round-trip; tests capped at 50.
- [ ] Step 2: Monitor tests with `FakePinger` (scripted RTTs) + `FakeWiFi`: after 6 rounds snapshot has stats; gateway never answers for 30 rounds (60 s) while internet answers → `gatewayPingable == false`; internet host falls back to 8.8.8.8 after 30 consecutive 1.1.1.1 failures while gateway answers; paused → rounds ignored.
- [ ] Step 3: Implement. Loop: every 2 s `pingRound`; minute boundary → aggregate + `store.append`; gateway re-resolved every 30 rounds; `isWired` = `wifi.currentLink() == nil` while pings succeed. Purge on start.
- [ ] Step 4: PASS; commit `ConnectionMonitor with persisted minute history and outage log`.

### Task 7: Connection rules, channel comparison, probe `--network`

**Files:** Create `Connection/ConnectionRules.swift`, `Connection/ChannelComparison.swift`; Modify `RulesEngine.swift` (CoreContext `connection: ConnectionSnapshot?`, evaluate param, add rules), `RulesConfig.swift` (`connection: ConnectionRuleConfig`), `SamplingPipeline.swift` (`tick(... connection:)`), `Sources/WhirrProbe/main.swift`; Tests `ConnectionRulesTests.swift`, `ChannelComparisonTests.swift`.

**Produces:** titles `"Wi-Fi is spiky"`, `"Problem is past your router"`, `"Weak Wi-Fi signal"`, `"Internet is down"`; `ConnectionRuleConfig { spikyWarnSpikes=6, spikyCritSpikes=20, spikyWarnLoss=2, spikyCritLoss=5, cleanMaxSpikes=3, cleanMaxLoss=1, weakRssi=-72, weakSnr=20 }`;
```swift
public struct ChannelStat: Equatable, Sendable { channel: Int; band: String; sessions: Int; spikesPerHour: Double; lossPercent: Double }
public struct ChannelComparison: Equatable, Sendable {
  public enum Period: String, Sendable { case evening, daytime }
  public let period: Period; public let qualified: [ChannelStat]; public let insufficient: [ChannelNeed]  // struct ChannelNeed: Equatable, Sendable { channel: Int; sessionsNeeded: Int }
  public let currentChannelWorsened: Bool
  public static func compute(_ aggs: [MinuteAggregate], networkId: String, currentChannel: Int?, period: Period, calendar: Calendar = .current) -> ChannelComparison
}
```
- [ ] Step 1: Rules tests: spiky thresholds (warn/crit), area `.connection`, action `.showHowTo(.changeWiFiChannel)`; past-router fires only when gateway clean; weak signal from rssi and from snr, never critical, nil when wired; outage critical with `.routerOutage`/`.ispOutage` how-to; `connection == nil` → no connection diagnoses.
- [ ] Step 2: Channel tests: sessions = distinct calendar days with ≥ 30 evening minutes; qualified needs ≥ 3 sessions; other networks excluded (**Review Focus 2**); spikes/hour = total gateway spikes / hours; worsened when last-3-sessions rate ≥ 2× prior median (needs ≥ 3 prior sessions).
- [ ] Step 3: FAIL → implement → PASS.
- [ ] Step 4: Probe `--network`: run `ConnectionMonitor` 30 s, print link, 1-min stats per hop, diagnoses from `RulesEngine.evaluate(..., connection:)`. Run it live; expected: link + stats print, no crash.
- [ ] Step 5: Commit `Connection rules, channel comparison, probe --network`.

### Task 8: Full test runner + report card

**Files:** Create `Connection/ConnectionTestRunner.swift`, `Connection/ConnectionReportCard.swift`; Tests `ConnectionReportCardTests.swift`, `NetworkQualityParseTests.swift`.

**Produces:**
```swift
public struct NetworkQualityResult: Codable, Sendable, Equatable { downMbps: Double?; upMbps: Double?; idleLatencyMs: Double?; loadedLatencyMs: Double? /* 60000/responsiveness RPM */ }
public struct ConnectionTestResult: Codable, Sendable, Identifiable { id: UUID; at: Date; networkId: String?; nq: NetworkQualityResult?; gatewayIdle: HopStats; gatewayLoaded: HopStats; link: WiFiLink?; neighbors: [NeighborCount] }
public enum Grade: String, Codable, Sendable { case good, ok, poor, unknown }
public struct ReportRow: Sendable, Equatable, Identifiable { id: String; title: String; grade: Grade; explanation: String; fix: String? }
public enum ConnectionReportCard { public static func rows(for r: ConnectionTestResult, passive10m gateway: HopStats, internet: HopStats) -> [ReportRow] }  // Speed, Stability, Under load, Wi-Fi crowding
public actor ConnectionTestRunner {
  public enum Phase: Sendable { case idle, measuringIdle, loading, scanning, done(ConnectionTestResult), failed(String) }
  public func run(onPhase: @Sendable (Phase) -> Void) async -> ConnectionTestResult
  public static func parse(networkQualityJSON: Data) -> NetworkQualityResult?
}
```
- [ ] Step 1: Parse test using real `networkQuality -c` keys: `dl_throughput`, `ul_throughput` (bps), `base_rtt` (ms), `responsiveness` (RPM). Garbage → nil.
- [ ] Step 2: Report card tests: speed ≥ 50 good / ≥ 25 ok / else poor / nil unknown; under-load delta < 30 good, < 100 ok, else poor — explanation says "Wi-Fi" when gatewayLoaded.median − gatewayIdle.median ≥ 50% of the total delta, else "internet line / router queue"; crowding: ≥ 6 neighbors on current channel poor, fix names least-crowded channel among 36–48 (non-DFS) on 5 GHz with DFS note; no Wi-Fi → crowding row "Wired — not applicable", grade unknown.
- [ ] Step 3: FAIL → implement → PASS. Runner: 5 s idle gateway pings @5 Hz; `Process` `/usr/bin/networkQuality -c -s` with concurrent gateway pings; then one scan; 90 s overall timeout → partial result.
- [ ] Step 4: Commit `On-demand connection test and report card`.

### Task 9: Main window shell, Overview, Mac, Developer, History; slim popover; activation policy

**Files:** Create `Sources/Whirr/MainWindow.swift`, `Sections/OverviewSection.swift`, `Sections/MacSection.swift`, `Sections/DeveloperSection.swift`, `Sections/HistorySectionView.swift`, `ActionHandler.swift`, `HowToSheet.swift`, `MenuPopoverView.swift`; Modify `WhirrApp.swift`, `SystemMonitor.swift` (own `ConnectionMonitor`, pass snapshot to pipeline, expose `connection`, `outages`, `tests`, `channelComparison`), `SettingsView.swift` (remove Insights tab, add Muted list + "Always show Developer"), `OnboardingView.swift` (open main window on finish). Delete usage of `MenuBarView` from scene (keep file only if referenced; otherwise remove).

- `MainWindow`: `NavigationSplitView` sidebar `List(selection:)` of `SidebarItem` enum (overview, mac, connection, history, developer), each row with status dot from `verdict.areaSeverity`; developer row only when `!dockerContainers.isEmpty || !harbrStatuses.isEmpty || Preferences.alwaysShowDeveloper`. Min size 760×520.
- Activation policy: `MainWindow` `.onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate() }`, `.onDisappear { NSApp.setActivationPolicy(.accessory) }`.
- `OverviewSection`: verdict card (headline title + detail + primary action button + snooze / "This is normal for me"), "Also:" list, Mac + Connection tiles (tap → navigate), all-clear state.
- `MacSection`: `HeadroomSection`, problems then notes for `.mac` (reuse `DiagnosesSection` filtered), top processes (move unified rows logic from `MenuBarView` into `TopProcessesList` view), daemon status row with how-to when `.undecodable`.
- `DeveloperSection`: existing `DockerGroupView`s + `HarbrSection` + `.developer` findings.
- `HistorySectionView`: `HistorySection` + `InsightsView` content + outages list + past tests list.
- `ActionHandler`: executes `SuggestedAction.Kind` (`quitApp` via existing force-quit path with confirm; `stopDocker` → `dockerClient` stop all running; `openURL`; `openSection` → selection binding; `runConnectionTest` → navigate to Connection and start; `showHowTo` → `HowToSheet`).
- `HowToSheet`: static plain-English content per `HowTo` case (channel change: open `http://<gateway>` or Optimum app → Wi-Fi settings → 5 GHz channel → pick suggested → save; note auto-channel re-rolls on reboot).
- `MenuPopoverView` (width 300): status dot + headline (or "Everything's running smoothly") + primary action + "Open Whirr…" (`openWindow(id: "main")`) + Settings / Quit.
- [ ] Steps: implement; `./build.sh`; launch `dist/Whirr.app`; verify each section renders with live data (screenshot if Screen Recording allowed, else accessibility text dump); commit `Main window with sidebar sections; slim menu popover`.

### Task 10: Connection section UI

**Files:** Create `Sources/Whirr/Sections/ConnectionSection.swift` (+ small subviews in same file if < 400 lines, else `ConnectionTestCard.swift`).

- Live link card: "Wi-Fi · 5 GHz channel 36 · Signal Good (−58 dBm)" with plain labels (signal: ≥ −60 Good, ≥ −70 OK, else Weak); "Wired" variant; internet-only notice when `!gatewayPingable`.
- Two hop rows "To your router" / "To the internet": typical delay, spikes last 10 min, loss — with a one-line verdict.
- Connection findings (problems + notes).
- "Check my connection" button → confirmation (~500 MB, ~30 s) → phase progress → report card rows (grade chip, explanation, fix).
- Channel comparison card (evening/daytime picker) with "Not enough data yet — N more evenings" state.
- Outage log: last 30 days, count, list, "Copy summary for your ISP" button (plain text to pasteboard).
- [ ] Steps: implement; build; run app; open Connection; run full test once live; verify report card; commit `Connection section: live link, stats, full test, channel comparison, outage log`.

### Task 11: Wrap-up

- [ ] README: replace dropdown description with window/sections + Connection; add `--network` probe flag; note the daemon reinstall command.
- [ ] Full `swift test`; `./build.sh`; install to `/Applications`; commit `README for window + connection`.
