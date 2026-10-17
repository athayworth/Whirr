import SwiftUI
import WhirrCore

extension Severity {
    var tint: Color {
        switch self {
        case .ok: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

extension DiagnosisContext {
    /// Notes read as calm information regardless of rule severity.
    var displayTint: Color {
        diagnosis.tier == .note ? .secondary : diagnosis.severity.tint
    }

    var symbol: String {
        if diagnosis.tier == .note { return "info.circle.fill" }
        return diagnosis.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
    }
}

/// One finding, in plain English, with its fix and quiet-it controls.
/// Used by every main-window section.
struct FindingCard: View {
    @Bindable var monitor: SystemMonitor
    let context: DiagnosisContext
    var isHidden = false

    @State private var confirming: SuggestedAction?

    private var diagnosis: Diagnosis { context.diagnosis }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: context.symbol)
                .font(.title3)
                .foregroundStyle(context.displayTint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(diagnosis.title).font(.headline)
                    if diagnosis.tier == .note {
                        Text("Note")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    Text(DurationText.words(seconds: context.durationSeconds))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("How long this has been going on")
                }
                Text(diagnosis.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                controls
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(context.displayTint.opacity(diagnosis.tier == .note ? 0.06 : 0.09))
        )
        .opacity(isHidden ? 0.55 : 1)
        .confirmationDialog(
            confirming?.label ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { action in
            Button(action.label, role: .destructive) { monitor.perform(action) }
        } message: { action in
            Text(ActionText.confirmation(for: action))
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 8) {
            if isHidden {
                if monitor.snoozeStore.isMuted(diagnosis.title) {
                    Button("Show this again") { monitor.snoozeStore.unmute(diagnosis.title) }
                } else {
                    Button("Unsnooze") { monitor.snoozeStore.unsnooze(diagnosis.title) }
                }
            } else {
                if let action = diagnosis.action {
                    Button(action.label) {
                        if ActionText.needsConfirmation(action) { confirming = action } else { monitor.perform(action) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(diagnosis.tier == .problem ? diagnosis.severity.tint : .accentColor)
                }
                Spacer()
                Menu {
                    Button("Snooze for 1 hour") { monitor.snoozeStore.snooze(diagnosis.title) }
                    Button("This is normal for me") { monitor.snoozeStore.mute(diagnosis.title) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Quiet this finding")
            }
        }
        .controlSize(.small)
        .padding(.top, 2)
    }
}

/// An area's other stories (the top one is in its answer card), then a
/// collapsible "quieted" group.
struct FindingsList: View {
    @Bindable var monitor: SystemMonitor
    let area: Diagnosis.Area

    @State private var showHidden = false

    var body: some View {
        let top = monitor.verdict.stories.first { $0.area == area }
        let rest = monitor.verdict.stories(in: area).filter { $0.id != top?.id }
        let hidden = monitor.hiddenContexts(in: area)
        if !rest.isEmpty || !hidden.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                let pendingIDs = Set(monitor.verdict.pendingStories.map(\.id))
                ForEach(rest) { StoryCard(monitor: monitor, story: $0, isPending: pendingIDs.contains($0.id)) }
                if !hidden.isEmpty {
                    DisclosureGroup(isExpanded: $showHidden) {
                        VStack(spacing: 8) {
                            ForEach(hidden) { FindingCard(monitor: monitor, context: $0, isHidden: true) }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("\(hidden.count) quieted").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Section heading used throughout the main window.
struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var term: Glossary.Term?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(title).font(.title3.weight(.semibold))
                if let term { InfoButton(term: term) }
            }
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
    }
}

/// Standard scrolling page for a sidebar section.
struct SectionPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(title)
    }
}
