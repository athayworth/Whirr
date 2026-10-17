# Easy when tired — design

Date: 2026-10-17 · Branch: `easy-when-tired` · Builds on
`2026-10-14-whirr-window-and-connection-design.md` and
`2026-10-17-connection-accuracy-and-learning-design.md`.

## Intent

Whirr should be usable by someone tired or exhausted. They open it for one of
two reasons: **something feels wrong right now** (lag, beachballs, fans), or
**a quick check that everything's fine**. Looking back (History) matters, but
second.

**Success:** within about five seconds of a glance, the person knows whether
anything is wrong, what it is, the one thing to do, and — if they want it —
why Whirr thinks so.

**Standing rule (unchanged):** Whirr only states what it measured. A "why" is
given only when the evidence supports it; otherwise Whirr says what it can't
tell and what's missing.

What the user said: answer-first in layers (dropdown → window); one combined
sentence plus one action, other causes as single lines; a short "because" in
the sentence with full "why" behind a button; History as a week sentence over
a compact day-grouped timeline; short pages that keep necessary detail one
click away; sidebar stays flat.

## Problems this fixes (observed on the live app, 2026-10-17)

1. Mac page headline "Working fine — 5.9 GB of headroom" above three red
   problem cards.
2. One cause shown as three cards: "Docker is a major load", "Virtualization
   VM has been pegging CPU", "System is overloaded".
3. Technical text on the surface: full executable paths, pids, "999 seconds".
4. History: an unexplained solid-red 30-minute bar; "older method" caveat
   repeated on every outage row; full dates on every row.
5. No calm "you're fine" state.

## 1. Screens

### Menu bar dropdown
- **Problem state:** status dot + one sentence covering every cause with
  evidence (most serious first, at most three phrases, then "and N more") +
  a "because" line with one measured number + one primary action button.
  Each remaining story: one "Also:" line with its own short because and a
  "Why?" link. Footer "Open Whirr → see why" opens the window on that story.
- **Calm state:** one green line, "All good. Mac and connection steady." and
  nothing else (plus the existing Open Whirr / Settings / Quit footer).
- **Pending state** (problem seen but inside the 2-minute gate): "Keeping an
  eye on something — <phrase>." No action button.

### Overview
- Answer card: the same sentence, because line and action as the dropdown,
  larger, with "Why?" expanding in place to **How Whirr knows** and **Why it
  matters**.
- Remaining stories as single lines beneath (because + Why?).
- Two status tiles: Mac and Connection, one line each in plain words.
- Calm state: a green answer card with the calm sentence; tiles still shown.

### Mac, Connection, Developer pages
Order on each page:
1. The area's answer card (or calm card).
2. Its findings as story cards — headline, because line, Why?, action.
   Notes stay visually quieter (grey, "note" chip).
3. Three key facts with ⓘ (Mac: memory pressure, workload, free disk.
   Connection: signal, router link, internet link. Developer: containers
   running, Docker memory, dev servers up).
4. Collapsible rows for everything else. Whirr remembers each row's open state
   (per-viewer convenience; `@AppStorage`).
   - Mac: What's using your Mac · All measurements · Background helper.
   - Connection: Wi-Fi details · Today · Check my connection (report card) ·
     How each channel has done · Channel changes · Outages.
   - Developer: Containers · Dev servers.

Display rules everywhere: durations in words ("17 min", "1 h 10 min"); no
paths, pids or command lines outside "Why?" → How Whirr knows.

### History
- **Week sentence** at the top (see §3).
- **One timeline**, newest first, grouped by day. Today open; older days are a
  single line ("6 outages · 6 min · Mac overloaded 2 h 10 min ›") that expands.
- Each event: time, a chip (Mac / Connection / Wi-Fi), a short description,
  duration. Events are Mac problems (problem tier only), outages and channel
  changes.
- The "older, less reliable method" caveat appears once per day that has such
  outages, not per row.
- Folded rows at the bottom: **Connection tests** and **Patterns** (which
  problems recur: "Docker overload on 4 of the last 7 days").
- Removed: the 30-minute severity bar and the Insights charts (`InsightsView`).

### Sidebar
Flat: Overview, Mac, Connection, History, Developer (when relevant), Learn.
Status dots on Mac and Connection unchanged. No nested items.

## 2. Stories and the "why"

### Diagnosis gains two fields
- `evidence: [String]` — measured facts with numbers, all from the sample
  that produced the finding. `evidence.first` is the because line. Empty means
  "nothing measured to show": the Why? button is hidden.
- `impact: String?` — one or two sentences on what this does to the person,
  phrased as general knowledge ("With every core busy, apps wait their turn"),
  never as an unmeasured claim about this Mac.
- Both decode tolerantly (old daemon payloads, old incident data).
- Where a cause can't be isolated, evidence says so and why ("Your router
  doesn't answer Whirr's checks, so Whirr can't tell whether this is Wi-Fi or
  the router").
- `detail` remains for the card body but no longer carries paths, pids or
  raw second counts; those move into evidence where useful.

### Story builder (`StoryBuilder`, WhirrCore, pure)
Input: classified diagnoses with contexts (as today), the sample's processes,
and whether every process is visible. Output: `[Story]`, ranked.

- **Culprit owner.** Each culprit name maps to an owner: Docker (com.docker.*,
  Virtualization VM processes when com.docker.backend runs), otherwise the
  friendly app name `ProcessDescriptor` already produces (helpers → their app).
- **Merge by owner.** Findings whose culprits share an owner become one story.
  Headline = most serious member (problem tier over note, then peak severity,
  then duration, then narrative over standalone). Other members become
  evidence lines prefixed with their title.
- **System-wide findings** (overloaded, memory saturated/tight, actively
  paging, thermal) join an owner's story only when that owner is measurably
  the largest contributor: ≥ 40 % of all CPU in use (only when every process
  is visible) for overloaded/thermal; ≥ 25 % of memory for memory findings.
  Otherwise they form their own story.
- **Phrase.** Each story has a short lowercase phrase for the combined
  sentence ("your Mac is overloaded", "your link to the router is stalling",
  "a backup is competing with your apps"). Phrases are per title; titles
  without one fall back to the lowercased title.
- **Combined sentence.** Problem stories past the 2-minute gate, ranked as
  `VerdictSelector` ranks today: "Your Mac is overloaded, and your link to the
  router is stalling." Max three phrases, then "and N more".
- **Action.** The top story's action.
- **Headroom consistency.** The Mac answer card is driven by stories, not by
  the headroom assessor; headroom becomes one of the key facts. "Working fine"
  can never sit above a problem.
- **Notifications.** One per story (keyed by the headline title); the 5-minute
  and actionable gates apply to the story.

### Accuracy tests
For each rule that emits evidence, a test asserts every number in its evidence
strings appears in (or is computed from) that rule's inputs. A shared helper
extracts numbers from strings and checks them against the inputs used to
build the test case.

## 3. History digest (`HistoryDigest`, WhirrCore, pure)

Inputs: incidents (closed, plus currently open problems), outages, channel
changes, tests, network id, now, calendar.

- **Incidents gain `tier`** (tolerant decode). Old incidents without it are
  classified by title through `FindingClassifier`'s note list (swap volume,
  idle hogs, low disk warning, Docker strain), so notes never appear as
  problems.
- **Day groups:** events per local day, newest first; a day line counts
  outages (with total minutes), Mac problem time per headline, channel
  changes.
- **Week sentence** (last 7 days), built only from countable facts:
  - "N short outages (M min total)" — always when N > 0.
  - "K of them between 9 pm and 3 am" — only when N ≥ 3 and K ≥ ⅔ N.
  - "Your Mac was <phrase> for T" — total problem time per top headline.
  - "mostly while <owner> was running" — only when the owner is among the
    incident's culprits for ≥ ⅔ of that time.
  - Outages recorded by the older method count toward totals but are excluded
    from the time-of-day and cause claims.
  - Nothing to report: "A quiet week: no outages and no Mac problems."
- **Patterns:** problem headlines that occurred on ≥ 3 of the last 7 days,
  "<headline> on D of the last 7 days".

## 4. Behind the scenes

- **Split `SystemMonitor`** (≈420 lines): `ConnectionController` (passive
  monitor, test runner, history store, connection state), `Navigation`
  (selected section, presented how-to, focused story, pending test). The
  monitor keeps Mac sampling and coordination.
- **History store robustness:** purge at most once a day while running, not
  only at launch; appends use the throwing `FileHandle.write(contentsOf:)` and
  ignore failures (disk full) instead of crashing; a torn last line is
  skipped (already) and the next append starts on a fresh line.
- **Retire** `InsightsView.swift` and `HistorySection.swift` (30-minute bar)
  once History is rebuilt.

## Out of scope
The "Explain & advise" AI button; Apple signing/notarization; new rules.

## Testing
TDD in WhirrCore for StoryBuilder, HistoryDigest, evidence accuracy, the
incident tier decode and the store robustness. Views verified on the live app
with screenshots of each section in problem and calm states. Fresh-context
whole-branch review at the end.
