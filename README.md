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

## Develop

```sh
swift build                 # compile both targets
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
```

Sampling runs every 3 seconds on a background actor; UI updates on `@MainActor`. Per-process CPU% is computed by diffing cumulative CPU times across two samples (same approach as `top`).

## Rules (v0.1)

- **MemoryPressureRule** — flags `.warning` / `.critical` based on free + compressed page ratios
- **SwapThrashingRule** — fires when ≥ 2 GB swap is in use; critical at 6 GB
- **ThermalThrottleRule** — surfaces `ProcessInfo.ThermalState ≥ .serious`
- **OverloadedSystemRule** — load average / core count ≥ 1.5
- **BackupHoggingRule** — Backblaze (`bzserv`, `bztransmit`), Time Machine (`backupd`), `rsync`, `restic`, `borg` using ≥ 5% CPU
- **RunawayProcessRule** — any single process ≥ 80% CPU

Adding a new rule = new `struct` conforming to `Rule` + one line in `RulesEngine.allRules`.

## License

MIT — see [LICENSE](LICENSE).
