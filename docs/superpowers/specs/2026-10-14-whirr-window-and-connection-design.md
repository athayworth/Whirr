# Whirr: main window + Connection monitoring — design

**Date:** 2026-10-14
**Status:** Approved in conversation (user waived written-spec review: "write the spec, commit it, then open fire")
**Follow-up spec (separate):** "Explain & advise" AI button via `claude -p` subprocess.

## 1. Why

Whirr's rules engine works, but the user rarely opens the app. Audit findings:

1. Everything lives in a 380×540 `MenuBarExtra` dropdown — headroom, diagnoses, history, Harbr, processes, Docker, daemon status, footer. Each section was added to fix a problem; the result is a dashboard crammed into a popover.
2. No single "what do I do first?" — on 2026-10-13 it showed 2 critical + 3 warning cards with equal visual weight.
3. The menu bar icon cries wolf (red most of the time on a dev machine: Docker running, parked swap).
4. **Bug:** the installed `/usr/local/bin/whirr-sampler` (built 2026-05-15 01:12) writes `ProcessSample` without `sustainedIdleSamples`, which was added 90 min later as a required key. Every daemon snapshot fails to decode and the app silently falls back to in-process sampling (no root-process visibility).
5. Uncommitted July work (`FrontmostAppTracker` — exempt recently focused apps from the "looks unused" narrative).

Separately, the user has real connection problems (GeForce NOW lag). A one-off audit on 2026-10-08 found: 193/31 Mbps capacity (fine), but router-hop ping spikes to 195 ms idle / 243 ms under load, bufferbloat 21 → 228 ms, 10 neighbor networks on channel 149. The router is on Optimum automatic channel selection and gets power-cycled often, so the channel re-rolls (it was on 36 on 2026-10-13).

## 2. Intent

**Usage modes (user's words: "A and C"):**
- **On demand:** something feels slow/laggy → open Whirr → it says why, and what to do.
- **Ambient:** runs quietly; only taps the user on the shoulder when something is wrong *and* worth fixing.

**Audience:** non-technical readers first. Developer detail available but out of the way. Still intended for public MIT release.

**Success criteria**
- Opening the window answers "is it my Mac or my connection, and what's the one thing to do?" within one glance.
- The menu bar icon is neutral most of the time on the user's dev machine.
- After a few evenings, Whirr can show whether the router's current channel performs better or worse than previous ones, and keeps a dated outage log attributable to router vs. ISP.

**Out of scope (this spec):** AI features; Sparkle/Dev ID distribution work (see TODO.md); per-container Docker history graphs.

## 3. Shape

### 3.1 App structure
- Whirr becomes a **window app with a menu bar presence**. When the main window is open, activation policy is `.regular` (Dock icon, Cmd-Tab); when it closes, back to `.accessory`. `LSUIElement` stays true so login launch is menu-bar-only.
- Main window: SwiftUI `Window` scene (single instance, id `main`), `NavigationSplitView` with a sidebar.
- **Menu bar popover** shrinks to: status dot + one-line headline + primary action button (if any) + "Open Whirr…" + Settings/Quit. Nothing else.
- First-run onboarding stays as is, but finishes by opening the main window.

### 3.2 Sidebar sections
| Section | Contents |
|---|---|
| **Overview** | Verdict card (one problem, plain English, one primary action) + "Also:" lines for other active problems + two tiles (Mac / Connection) with status dot and one line each. All-clear state: "Everything's running smoothly." |
| **Mac** | Headroom summary, problems + notes for the Mac, top processes (unified list), memory/disk/heat facts, daemon status. Reuses `DiagnosesSection`, `ProcessRow`, `HeadroomSection`. |
| **Connection** | Live link card, passive stats, per-channel comparison, outage log, "Check my connection" full test + report card. |
| **History** | Existing trend strip + incident insights (moved from Settings → Insights) + network stats over time + past full-test results. |
| **Developer** | Docker groups, Harbr dev servers, force-quit by PID. Shown only when Docker or Harbr is detected, or forced on in Settings. |

Each sidebar row shows a status dot (green / yellow / red / none) derived from the problems in that area.

### 3.3 Under the hood
- `WhirrCore` engine (samplers, `RulesEngine`, narratives, `DiagnosisDurationTracker`, `SnoozeStore`, `IncidentLog`) is retained.
- Network measurement is a new `WhirrCore` subsystem whose output feeds the same rules pipeline, so connection problems are ordinary `Diagnosis` values and compete for the Overview headline under one priority scheme.
- Network sampling runs **in the app process**, not the root daemon (unprivileged ICMP and CoreWLAN reads both work as the user — verified 2026-10-13).

## 4. Findings model (fixes cry-wolf)

Add to `Diagnosis` (additive, backward-compatible decode):

```swift
public enum Tier: String, Codable, Sendable { case problem, note }
public enum Area: String, Codable, Sendable { case mac, connection, developer }
public let tier: Tier          // default .problem
public let area: Area          // default .mac
public let action: SuggestedAction?   // nil = no actionable fix
```

`SuggestedAction` is a small value type: `label` ("Stop Docker", "Change Wi-Fi channel") + `kind` enum (`.quitApp(pid)`, `.stopDocker`, `.openURL(URL)`, `.openSection(Area)`, `.runConnectionTest`, `.showHowTo(String)` — a short plain-English instruction sheet). The UI maps kinds to handlers; rules only describe.

**Re-tiering existing rules**
- `Swap is holding old pages` → note.
- `Disk is nearly full` → note at warning, problem at critical.
- `Docker is using significant resources` → area `.developer`, tier note **unless** a system-strain diagnosis (overloaded / memory saturated / actively paging / thermal) is also active — then problem, area `.mac`, action `.stopDocker`.
- `Big processes that look unused` → note.
- All others stay problems in `.mac`.

**Headline selection** (pure function, `WhirrCore/VerdictSelector.swift`, unit-tested): among unsnoozed, unmuted `problem`s whose duration ≥ 2 min, pick max severity; ties → longest duration; then narratives over standalone. Others become "Also:" lines. Notes never headline.

**Menu bar icon:** colored only from problems that pass the same 2-min gate. Notes never color it.

**Notifications:** only for problems that are critical, sustained ≥ 5 min, have an `action`, and aren't snoozed or muted; once per incident (existing `DiagnosisChangeTracker` edge logic, with the 5-min gate added in front).

**Mute ("This is normal for me"):** permanent per-title mute stored alongside snoozes (`SnoozeStore` gains `mute(title)` / `unmute` / `mutedTitles`). Muted findings render dimmed in their section with an "Unmute" control; Settings lists all mutes with restore buttons.

## 5. Connection subsystem

### 5.1 Passive watcher (`ConnectionMonitor` actor, WhirrCore)
- Every **2 s**: one ICMP echo to the default gateway and one to `1.1.1.1` (fallback `8.8.8.8` if 1.1.1.1 fails 30 consecutive times while the gateway answers). Unprivileged `SOCK_DGRAM`/`IPPROTO_ICMP` sockets, 1 s timeout. ~10 MB/day.
- Every **3 s** (pipeline tick): read Wi-Fi link via CoreWLAN — RSSI, noise, channel number + band + width, transmit rate, PHY mode. No SSID (requires Location; not needed).
- **Never scans** in the background (scans take the radio off-channel and cause spikes).
- Gateway discovery via routing table (`route get default` equivalent through `sysctl` `NET_RT_FLAGS`, or `SCDynamicStore` `State:/Network/Global/IPv4` → `Router`). Re-resolved each minute and on network change (`NWPathMonitor`).
- **Network identity** = gateway MAC (BSSID unavailable without Location; gateway hardware address from ARP table is stable per home router). History and outage data are keyed per network identity, so other networks don't pollute home stats.
- If the gateway never answers ICMP over the first 60 s on a network while the internet host does, mark `gatewayPingable = false` and run internet-only (UI says so).
- Pauses on sleep (`NSWorkspace.willSleepNotification` / `didWake`); resumes with a 10 s settle.
- On Ethernet (no Wi-Fi interface active / primary interface not Wi-Fi): pings continue; Wi-Fi readings skipped; UI says "Wired".

**Rolling stats** (`ConnectionStats`, pure value, unit-tested), per hop (gateway / internet) over the last 60 s and last 60 min:
- median RTT, p95 RTT, jitter (mean abs successive diff), loss %, spike count. A **spike** = RTT > max(median×3, median+50 ms) or timeout.

**Persistence:** `ConnectionHistoryStore` writes per-minute aggregates (per hop: median, p95, loss, spikes; plus Wi-Fi channel/band/RSSI/noise/txRate mode for that minute; network id) to `~/Library/Application Support/Whirr/connection-history.jsonl`. Retention 30 days, purged on launch and daily.

### 5.2 Outage log
- **Outage** = both hops fail for ≥ 10 s consecutively (≥ 5 missed pings). Attribution:
  - gateway down → `.router` ("Router stopped responding")
  - gateway up, internet down ≥ 10 s → `.isp` ("Internet line went down — router was fine")
  - Wi-Fi association lost → `.wifiDisconnected`
- Stored as `OutageRecord { start, end, cause, networkId }` in `outages.json`. Shown in Connection as a dated list with durations and a monthly count, with a copyable plain-text summary for calling the ISP.

### 5.3 Connection rules (in `RulesEngine`, area `.connection`)
Fed a `ConnectionSnapshot` (current link + 60 s / 10 min stats + gatewayPingable + isWired) via the existing `CoreContext`.
- **Wi-Fi is spiky** — gateway hop, 10-min window: spikes ≥ 6/10 min or loss ≥ 2% → warning; spikes ≥ 20 or loss ≥ 5% → critical. Action: `.showHowTo` channel-change instructions (+ `.runConnectionTest`).
- **Problem is past your router** — gateway hop clean (spikes < 3, loss < 1%) and internet hop spikes ≥ 6 or loss ≥ 2% over 10 min. Action: `.showHowTo` "what to tell your ISP".
- **Weak Wi-Fi signal** — RSSI < −72 dBm or SNR < 20 dB sustained 60 s → warning problem (never critical — weak signal alone is a contributing factor, not an outage). Action: `.showHowTo` placement tips.
- **Internet outage in progress** — current outage → critical, area connection, action `.showHowTo` (router vs ISP specific).
- Thresholds live in `RulesConfig` (new `connection` section) so `rules.json` can tune them.

### 5.4 Per-channel comparison (`ChannelComparison`, pure, unit-tested)
- From per-minute history for the current network: group by channel, restricted to the same **hour-of-day band** as "evening" (17:00–23:00) and "daytime" (09:00–17:00) separately.
- Metric: gateway spikes/hour and loss %. Report only channels with ≥ 3 distinct evenings (or days) of ≥ 30 min data each; else "Not enough data yet — N more evenings".
- Drift: if the current channel's last-3-evenings spike rate ≥ 2× its own prior median → "Your channel has gotten worse lately" note with `.runConnectionTest`.
- UI copy is explicitly comparative, never "best channel": "Channel 36: 2 spikes/hr over 4 evenings · Channel 149: 14 spikes/hr over 2 evenings."

### 5.5 Full test ("Check my connection")
`ConnectionTestRunner` (WhirrCore actor), ~30 s, user-triggered only, confirmation mentions ~500 MB data use:
1. `/usr/bin/networkQuality -c -s` (sequential, JSON) → down/up capacity, idle latency, responsiveness under load. Missing binary/timeout → rows marked "couldn't measure".
2. Concurrent gateway pings at 5 Hz during the load phase → gateway latency under load (splits Wi-Fi bloat from ISP bloat).
3. One CoreWLAN `scanForNetworks` after the load test → neighbor count per channel on the current band.

**Report card** (`ConnectionReportCard`, pure function of raw results, unit-tested): four rows, each grade (Good / OK / Poor / Couldn't measure) + one-line explanation + fix:
- **Speed** (capacity vs. 25 Mbps streaming need)
- **Stability** (passive 10-min gateway & internet stats)
- **Under load** (idle → loaded latency delta; attributes to Wi-Fi if gateway-under-load inflates, else ISP/router queue)
- **Wi-Fi crowding** (neighbors on current channel; suggests the least-crowded non-DFS channel group, mentions DFS trade-off)

Results saved to `connection-tests.json` (last 50) and shown in Connection + History.

## 6. Housekeeping included
- **Tolerant `ProcessSample` decode:** hand-rolled `init(from:)`; all fields after `sustainedHighCpuSamples` `decodeIfPresent` with defaults, matching the `SystemSnapshot` pattern. Test with the real May-format payload shape.
- **Stale-daemon visibility:** `SamplingPipeline.Result` exposes `daemonStatus: .fresh / .stale / .undecodable / .absent`; Mac section shows "Advanced sampling unavailable — sampler is out of date" with reinstall instructions when undecodable.
- Commit the July `FrontmostAppTracker` work (tests already in tree).
- Move Insights from Settings into History.

## 7. Error handling summary
| Situation | Behavior |
|---|---|
| Asleep | Connection monitor paused; no samples recorded; not an outage |
| Wired | Pings continue; Wi-Fi rows show "Wired" |
| Gateway blocks ICMP | Internet-only mode, labeled |
| Different network | Separate history keyed by gateway MAC |
| `networkQuality` fails | Partial report card, "couldn't measure" rows |
| CoreWLAN unavailable | Wi-Fi rows hidden; pings still work |
| Daemon payload undecodable | In-process fallback + visible status row |

## 8. Testing
- Unit tests (XCTest, existing style) for: tolerant decode, `ConnectionStats`, outage detection/attribution, each connection rule, `ChannelComparison`, `ConnectionReportCard`, `VerdictSelector`, tier/area re-mapping (Docker escalation), mute in `SnoozeStore`.
- Pinger and Wi-Fi reader behind protocols (`Pinging`, `WiFiReading`) with fakes; tests never touch the network.
- `whirr-probe --network` prints live link, 30 s of ping stats, and connection diagnoses against the real machine.
- UI verified by running the built app and viewing each section (screenshots require Screen Recording permission for the terminal; otherwise manual check).

## 9. Build order (for the implementation plan)
1. Housekeeping: commit WIP, tolerant decode, daemon status.
2. Findings model (tier/area/action), mute, VerdictSelector, re-tier rules, notification gate.
3. Connection core: pinger, Wi-Fi reader, stats, monitor, outage detection, history store.
4. Connection rules + channel comparison + probe `--network`.
5. Full test runner + report card.
6. Window shell + Overview + Mac + Developer + History sections; slim popover; activation policy.
7. Connection section UI.
