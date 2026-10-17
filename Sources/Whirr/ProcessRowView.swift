import SwiftUI
import WhirrCore

/// A clickable process row. Renders compactly (safety pill + friendly
/// name + caller-supplied trailing content). Tapping it expands an
/// inline detail panel underneath; tapping again collapses. Only one
/// row across the whole menu can be expanded at a time.
///
/// The "friendly name" comes from `ProcessDescriptor` — an app name
/// resolved from Info.plist or a curated known-name table, so users
/// see "Google Chrome" rather than "Google Chrome Helper (Renderer)".
struct ProcessRow<Trailing: View>: View {
    let proc: ProcessSample
    @Binding var expandedPid: Int32?
    let parentLookup: (Int32) -> ProcessSample?
    /// When true, drop the safety pill and chevron for a tighter row.
    /// The row is still clickable to expand — we just hide the affordance
    /// glyph. Row height drops by ~4 pt and horizontal noise drops too.
    let compactMode: Bool
    /// Real seconds between samples, for "idle Nm" and the growth window.
    var secondsPerSample: Double = 3
    @ViewBuilder var trailing: () -> Trailing

    private var isExpanded: Bool { expandedPid == proc.pid }
    private var safety: ProcessSafety { ProcessClassifier.classify(proc) }
    private var description: ProcessDescription {
        ProcessDescriptor.shared.describe(proc)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expandedPid = isExpanded ? nil : proc.pid
            } label: {
                HStack(spacing: 8) {
                    if !compactMode {
                        SafetyBadge(safety: safety)
                    }
                    Text(description.friendlyName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    trailing()
                    if !compactMode {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(description.explainer)

            if isExpanded {
                ProcessDetail(
                    proc: proc,
                    safety: safety,
                    description: description,
                    parentLookup: parentLookup,
                    secondsPerSample: secondsPerSample
                )
            }
        }
    }
}

private struct ProcessDetail: View {
    let proc: ProcessSample
    let safety: ProcessSafety
    let description: ProcessDescription
    let parentLookup: (Int32) -> ProcessSample?
    let secondsPerSample: Double
    /// Drives a native confirmationDialog before SIGKILL. Consistent
    /// with the Docker "Stop all" / "Restart all" affordances.
    @State private var showForceQuitConfirm = false

    private var parent: ProcessSample? {
        guard let ppid = proc.parentPid, ppid > 1 else { return nil }
        return parentLookup(ppid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ELI5 first — "This is Slack, the chat app…" — then the
            // safety-oriented advice ("safe to Cmd-Q") beneath. The
            // ordering matches how someone actually reads: what is it,
            // then what should I do about it.
            VStack(alignment: .leading, spacing: 4) {
                if description.friendlyName != proc.name {
                    // Show the raw process name so users understand
                    // where the friendly label came from — otherwise
                    // the disambiguation feels like magic.
                    Text("This is **\(description.friendlyName)** (process: `\(proc.name)`).")
                        .font(.caption)
                        .foregroundStyle(.primary)
                } else {
                    Text("**\(description.friendlyName)**")
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                Text(description.explainer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(safety.advice)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 3) {
                detailRow("pid", "\(proc.pid)")
                if let parent {
                    detailRow("parent", "\(parent.name) (pid \(parent.pid))")
                } else if let ppid = proc.parentPid {
                    detailRow("parent", "pid \(ppid)")
                }
                if let uid = proc.userId {
                    detailRow("uid", uid == 0 ? "root" : "\(uid)")
                }
                if let path = proc.executablePath {
                    detailRow("path", path)
                }
                if let cmd = proc.commandLine, cmd != proc.name, cmd != proc.executablePath {
                    detailRow("command", cmd)
                }
            }

            HStack(spacing: 6) {
                Text("\(MenuFormat.cpu(proc.cpuPercent)) CPU")
                Text("·")
                Text(MenuFormat.bytes(proc.memoryBytes))
                if let delta = proc.memoryDelta10MinBytes, delta >= 100 * 1_048_576 {
                    Text("·")
                    Text("+\(MenuFormat.bytes(UInt64(delta))) /\(Int((200 * secondsPerSample / 60).rounded()))m")
                        .foregroundStyle(.red)
                }
                if proc.sustainedIdleSamples >= 100 {
                    Text("·")
                    Text("idle \(Int(Double(proc.sustainedIdleSamples) * secondsPerSample / 60))m")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Activity Monitor") {
                    let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
                    NSWorkspace.shared.open(url)
                }
                .controlSize(.small)

                // Helper rule of thumb: quit the parent app instead.
                if safety == .helper, let parent, parent.userId == getuid() {
                    Button("Quit \(parent.name)") {
                        _ = kill(parent.pid, SIGTERM)
                    }
                    .controlSize(.small)
                    .help("Sends SIGTERM to the parent app (\(parent.name), pid \(parent.pid)).")
                } else if proc.userId == getuid() {
                    Button("Quit") {
                        _ = kill(proc.pid, SIGTERM)
                    }
                    .controlSize(.small)
                    .help("Sends SIGTERM. The process should exit cleanly.")
                }

                if proc.userId == getuid() {
                    Button("Force quit") {
                        showForceQuitConfirm = true
                    }
                    .controlSize(.small)
                    .help("SIGKILL — abrupt, can lose unsaved state. Confirms before sending.")
                }
                Spacer()
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .confirmationDialog(
            "Force quit \(proc.name)?",
            isPresented: $showForceQuitConfirm
        ) {
            Button("Force quit (SIGKILL)", role: .destructive) {
                _ = kill(proc.pid, SIGKILL)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("SIGKILL is abrupt — unsaved work in this process will be lost.")
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)
            Text(value)
                .font(.caption2)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SafetyBadge: View {
    let safety: ProcessSafety

    var body: some View {
        Text(safety.label)
            .font(.caption2.monospaced())
            .foregroundStyle(textColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.18), in: Capsule())
            .help(safety.advice)
            .frame(minWidth: 42, alignment: .center)
            // The short label ("dev", "?", "helper") is useless to VoiceOver
            // on its own — expand into the full advice line so the safety
            // hint actually lands without sight of the colored capsule.
            .accessibilityLabel("\(accessibilityName): \(safety.advice)")
    }

    private var accessibilityName: String {
        switch safety {
        case .systemCritical: return "System-critical"
        case .systemService:  return "System service"
        case .userApp:        return "User app"
        case .helper:         return "Helper process"
        case .devTool:        return "Dev tool"
        case .unknown:        return "Unknown source"
        }
    }

    private var tint: Color {
        switch safety {
        case .systemCritical: return .red
        case .systemService:  return .gray
        case .userApp:        return .blue
        case .helper:         return .purple
        case .devTool:        return .green
        case .unknown:        return .orange
        }
    }

    private var textColor: Color {
        switch safety {
        case .systemCritical: return .red
        case .systemService:  return .secondary
        case .userApp:        return .blue
        case .helper:         return .purple
        case .devTool:        return .green
        case .unknown:        return .orange
        }
    }
}
