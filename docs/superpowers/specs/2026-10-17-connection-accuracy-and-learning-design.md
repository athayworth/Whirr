# Connection accuracy + built-in learning — design

Date: 2026-10-17 · Branch: `connection-accuracy` · Builds on `2026-10-14-whirr-window-and-connection-design.md`

## Why

Real use exposed claims Whirr couldn't back up. The test's crowding row called
channel 40 "empty" while seven 80 MHz networks covered it, because Whirr counted
exact channel numbers and ignored channel width. The user's rule for Whirr from
now on:

> Everything Whirr shows must be accurate and supported by evidence it actually
> has. No inferring what it can't prove. No false positives.

The user also wants to *learn* what the numbers mean, inside the app.

## Principle (applies to every change below and to all future copy)

1. **Say what was measured.** "Whirr heard 9 networks on your stretch of
   airwaves" — not "9 neighbors".
2. **Attribute a cause only with evidence that isolates it.** "Beyond your
   router" only when the router hop was measured *and* clean. "On your Wi-Fi"
   only when the router hop itself stalled.
3. **Recommend a fix only when evidence implicates what it fixes.** Never
   "change your channel" unless Whirr saw Wi-Fi-side stalls or Wi-Fi-side
   slowdown under load.
4. **General knowledge is framed as general knowledge** ("Common causes
   are…"), never as a finding.
5. **Unknown is a valid answer.** Missing data shows "—" or "Whirr can't tell
   because…", never a default that reads as a measurement (e.g. "0 networks"
   from a failed scan).

## Changes

### 1. Channel geometry (`WiFiSpectrum`, WhirrCore)
Pure functions over (band, primary channel, width):
- `occupied(band:channel:width:) -> ChannelBlock?` — the run of 20 MHz
  channels a network actually uses. 5 GHz blocks follow the standard
  alignment (80 MHz: 36–48, 52–64, 100–112, 116–128, 132–144, 149–161;
  40 MHz pairs; 160 MHz 36–64, 100–128, 149–177). 6 GHz: same rule from
  channel 1 in steps of 4. 2.4 GHz: 20 MHz centred on the channel ±2
  (channels 1/6/11 don't overlap); 40 MHz on 2.4 GHz can extend either way
  and CoreWLAN doesn't say which, so it is treated as covering both sides.
- `overlaps(a, b)` — frequency ranges intersect, same band.
- `isDFS` — 5 GHz channels 52–144 (radar-shared).
- `candidateBlocks(band:width:)` — every block of that width in the band.
- Labels: "channels 149–161" for wide blocks, "channel 36" for 20 MHz.

### 2. Neighbor scan
- `WiFiReading.scanNeighbors() -> [NeighborNetwork]?` — one entry per heard
  network: band, primary channel, width, RSSI. `nil` = the scan failed. An
  empty scan while associated also counts as failed (the Mac's own network
  is always audible), so "0 networks" is never invented.
- `ConnectionTestResult.neighbors: [NeighborNetwork]?`. Results saved by the
  previous version (per-channel counts, no width) decode as `nil` → crowding
  shows "This test ran on an older version of Whirr — run it again".

### 3. Crowding row (report card)
- Explanation: "During the test Whirr heard N Wi-Fi networks using the same
  stretch of airwaves as yours (5 GHz channels 149–161), including yours. One
  router can broadcast more than one network, and a single scan can miss some."
- "Loud" = heard at −82 dBm or stronger (the level at which Wi-Fi radios must
  wait for each other). Grade from the loud count: ≤2 good, 3–5 ok, ≥6 poor.
  This grades the *airwaves*, which were measured.
- Fix is evidence-gated: shown only if the same test or the passive router hop
  shows Wi-Fi-side trouble (router-hop stalls in the last 10 min, or router
  delay rising under load ≥ half the total rise). Otherwise: "Your Wi-Fi link
  to the router has been steady, so this crowding isn't causing problems right
  now."
- When a fix is shown, it lists the quietest blocks at the router's current
  width, non-radar first, with counts, and says "if your router lets you
  choose a channel". Radar-shared blocks carry the brief-dropout caveat.

### 4. Minute history
- `MinuteAggregate.widthMHz: Int?` (absent in old lines → nil).
- Fix: the aggregate for a minute records the Wi-Fi link seen during that
  minute's last round, not the next minute's first.

### 5. Channel comparison by block
Group by (band, occupied block). Old minutes without width group by
(band, channel) and are labelled "channel 36 (width not recorded)". The
"current" marker and the "gotten worse" check use the current block.

### 6. Channel-change log (`ChannelChangeLog`, WhirrCore)
Derived from minute history — no new storage. Consecutive minutes on the same
network whose (band, primary channel, width) differ produce a change. If the
two minutes are more than 5 minutes apart, the change is reported as
"sometime between X and Y" (Whirr wasn't watching). Wording names what was
measured: "Your Mac's Wi-Fi moved from 5 GHz channel 36 to channel 157". A
band change reads "Your Mac switched from 5 GHz to 2.4 GHz". Shown in
Connection → "Channel changes" (last 30 days).

### 7. "Today, which side?" summary (`DaySummary`, WhirrCore)
From today's minute history on the current network:
- < 30 minutes watched → "Not enough data yet today."
- Router hop measured, clean (< 18 stalls/hour and < 1% lost) and internet hop
  clean → "Steady on both sides today."
- Router hop clean, internet hop not → "Stalls today were beyond your
  router — your provider's side." (with counts)
- Router hop not clean → "Your Wi-Fi link to the router stalled N times
  today." No claim about the provider (router stalls contaminate the internet
  hop).
- Router never answered → counts only, plus "Whirr can't separate Wi-Fi from
  your provider because your router doesn't answer its checks."

### 8. Rule and report-card wording
- SpikyWiFiRule: "Common causes are a crowded channel or a weak signal. The
  connection test shows which applies." Action → run connection test.
- Stability row fix (Wi-Fi stalls): names weak signal if the current link is
  weak; otherwise points at the test / crowding row rather than prescribing a
  channel change.
- Changing-channel how-to: describes picking an empty *strip*, mentions
  Smart WiFi-style automatic modes, and that the test lists quiet strips.
- Plus whatever the independent accuracy audit confirms (see ledger below).

### 9. Learning: info buttons + Learn section
- `Glossary` (WhirrCore): `Term` enum; each has a title, a one-sentence
  `short` and a plain-English `detail` (analogy where it helps). Connection
  terms: signal strength (dBm), signal above noise (SNR), band, channel,
  channel width, radar-shared channels, automatic channel selection, router
  hop, internet hop, delay (ms), stall, lost checks, speed (Mbps), delay under
  load, crowding, outage, link rate. Mac terms: memory pressure, swap, CPU,
  workload, heat, disk space.
- `InfoButton(term)`: small ⓘ next to a label; click opens a popover with the
  detail and "See all in Learn". Hover shows `short` as a tooltip.
- Sidebar "Learn" section: every term, grouped Connection / Mac.
- Tests: every term has non-empty, distinct title/short/detail; `short` ≤ 160
  characters.

## Out of scope
AI "Explain & advise" (separate spec). BSSID/SSID-based dedupe (needs Location
permission; Whirr stays permission-free).

## Testing
TDD in WhirrCore for 1–7 and the glossary. App views are built and checked on
the live app. Fresh-context whole-branch review at the end.
