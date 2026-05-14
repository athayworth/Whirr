# Whirr

A macOS menu bar app that tells you **why** your Mac is slow — not just how slow.

Most performance monitors (Stats, iStat Menus, Activity Monitor) show gauges and let you draw your own conclusions. Whirr runs a rules engine over CPU, memory, swap, thermal, and per-process activity, and surfaces a plain-English diagnosis: *"Backup is hammering your system"*, *"Memory is saturated — apps will stutter"*, *"CPU is throttling from heat"*.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode command-line tools (`xcode-select --install`) — Swift 5.10+

## Build

```sh
./build.sh
open dist/Whirr.app
```

To install to `/Applications`:

```sh
./build.sh
cp -R dist/Whirr.app /Applications/
```

To launch at login: System Settings → General → Login Items → add Whirr.

### Optional: privileged sampler daemon

Without the daemon, Whirr can read CPU/memory/disk for processes owned by your user. To also see root-owned processes (`WindowServer`, `mds_stores`, `backupd`, Backblaze daemons, etc.), install the launchd-managed sampler:

```sh
./build.sh                          # builds the daemon binary too
sudo scripts/install-sampler.sh     # installs and starts the daemon
```

What the install script does (review it before running):

- Copies `whirr-sampler` to `/usr/local/bin/`
- Creates `/Library/Application Support/Whirr/` (root-owned)
- Drops `com.whirr.sampler.plist` in `/Library/LaunchDaemons/`
- Loads the daemon, which writes `snapshot.json` to the data dir every 3 seconds
- Logs to `/var/log/whirr-sampler.log`

The menu bar app automatically prefers the daemon's snapshot when it's fresh (< 10 s old) and falls back to in-process sampling otherwise. There is no "is the daemon installed?" check — if the file is there and current, it's used.

Output-path validation: the sampler refuses to write anywhere outside `/Library/Application Support/Whirr/`, even when launched with arbitrary command-line arguments. This is enforced even at root, so a misconfigured invocation can't redirect output.

To uninstall:

```sh
sudo scripts/uninstall-sampler.sh
```

## Develop

```sh
swift build                 # compile both targets
swift test                  # unit tests for the rules engine
swift run whirr-probe       # CLI probe — verifies samplers + rules, prints a snapshot
swift run Whirr             # run the menu bar app from terminal (logs to stdout)
```

## Architecture

```
Sources/
  WhirrCore/                # Pure library — sampling and rules logic
    Models.swift            # Diagnosis, ProcessSample, SystemSnapshot, Severity
    SystemSampler.swift     # host_statistics64 + sysctl + thermalState
    ProcessSampler.swift    # proc_listpids + proc_pidinfo + proc_name (libproc)
    RulesEngine.swift       # Pluggable rules over the above
  Whirr/                    # SwiftUI menu bar app (depends on WhirrCore)
    WhirrApp.swift          # @main + MenuBarExtra scene
    SystemMonitor.swift     # @Observable wrapper + sampling loop
    MenuBarView.swift       # Dropdown UI
    Resources/Info.plist    # LSUIElement=true (no dock icon)
  WhirrProbe/               # CLI test runner that prints a single diagnosis
  WhirrSampler/             # Privileged sampler daemon (run as root via launchd)
Tests/
  WhirrCoreTests/           # XCTest unit tests for the rules engine + payload codec
scripts/
  com.whirr.sampler.plist   # launchd plist for the sampler daemon
  install-sampler.sh        # one-time install (requires sudo)
  uninstall-sampler.sh      # tear-down (requires sudo)
```

Sampling runs every 3 seconds on a background actor; UI updates on `@MainActor`. Per-process CPU% is computed by diffing cumulative CPU times across two samples (same approach as `top`).

## Rules (v0.1)

- **MemoryPressureRule** — flags `.warning` / `.critical` based on free + compressed page ratios
- **SwapThrashingRule** — fires when ≥ 2 GB swap is in use; critical at 6 GB
- **ThermalThrottleRule** — surfaces `ProcessInfo.ThermalState ≥ .serious`
- **OverloadedSystemRule** — load average / core count ≥ 1.5
- **BackupHoggingRule** — Backblaze (`bzserv`, `bztransmit`), Time Machine (`backupd`), `rsync`, `restic`, `borg` — fires on either ≥ 5 % CPU or ≥ 5 MB/s sustained disk I/O (backups are usually I/O-bound, not CPU-bound)
- **HighDiskIORule** — any single non-backup process reading or writing ≥ 50 MB/s sustained; critical at 200 MB/s
- **RunawayProcessRule** — any single process ≥ 80% CPU

Adding a new rule = new `struct` conforming to `Rule` + one line in `RulesEngine.allRules`. Rules are pure functions of their inputs — see `Tests/WhirrCoreTests/RulesEngineTests.swift` for the testing pattern.

### Narratives

After the rules above fire, a second pass runs **narrative rules** that see the produced diagnoses and synthesize a multi-signal explanation. These render as a highlighted card at the top of the menu — the "why your Mac is slow" story rather than a list of facts.

- **BackupChokingForegroundNarrative** — backup hogging + any of (memory tight / swap / thermal) → "Foreground apps will feel frozen. Pause the backup."
- **MemorySwapSpiralNarrative** — memory saturated + heavy swap (no backup) → names your top memory hog as the fastest win.
- **ThermalThrottleAmplifierNarrative** — thermal throttle + a CPU-pegged process → "Cooling matters more than killing right now."
- **DiskMemoryContentionNarrative** — heavy disk I/O + memory pressure (no backup or memory-swap spiral) → "Disk and memory are fighting for the same SSD."

Precedence is hand-wired: more specific narratives suppress less specific ones via the conditions they check, not by inspecting each other's titles. Add a precedence test alongside any new narrative.

## License

MIT — see [LICENSE](LICENSE).
