import SwiftUI
import WhirrCore

/// Diagnoses block: empty/sampling state on top, then narrative cards
/// (the "story") followed by standalone rows. Splits snoozed items into
/// a collapsed footer so the user can see what's hidden without it
/// dominating the menu.
///
/// The rules engine sorts the input; this view just filters + renders.
struct DiagnosesSection: View {
    let hasSampledYet: Bool
    let contexts: [DiagnosisContext]
    let snoozeStore: SnoozeStore
    /// When true: drop the duration/trend meta badges and shrink the
    /// space between rows. Snooze buttons stay — they're small and
    /// their absence would strand snoozed items with no way to unsnooze
    /// beyond the collapsed footer.
    let compactMode: Bool
    @State private var showingSnoozed: Bool = false
    /// User's expand-all toggle for the diagnoses list. Persisted so
    /// their preference sticks across menu opens. When false, we cap
    /// visible rows at `initialDiagnosisCount` and stash the rest
    /// behind a "+N more" disclosure. Narratives (the highlighted
    /// cards) always render — they're the top-line story — so the cap
    /// only trims standalone rows.
    @AppStorage("preferences.diagnosesExpandAll") private var expandAllDiagnoses: Bool = false

    /// Max number of *standalone* rows shown before we start collapsing.
    /// Narratives are always rendered (they're the top-line story) and
    /// counted separately below.
    private static let standaloneVisibleCap: Int = 3

    var body: some View {
        if !hasSampledYet {
            samplingState
        } else if visibleContexts.isEmpty && snoozedContexts.isEmpty {
            normalState
        } else {
            VStack(alignment: .leading, spacing: compactMode ? 6 : 10) {
                if visibleContexts.isEmpty && !snoozedContexts.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "moon.zzz.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("All active diagnoses are snoozed.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                // Narratives lead — always shown, always full.
                ForEach(visibleNarratives) { context in
                    NarrativeCard(context: context, snoozeStore: snoozeStore, compactMode: compactMode)
                }
                // Standalone rows follow, capped unless the user
                // asked for the full list. Cap keeps the menu height
                // sane when many rules fire simultaneously.
                ForEach(shownStandaloneRows) { context in
                    DiagnosisRow(context: context, snoozeStore: snoozeStore, compactMode: compactMode)
                }
                if hasHiddenStandaloneRows {
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            expandAllDiagnoses.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: expandAllDiagnoses ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                            Text(hiddenStandaloneLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if !snoozedContexts.isEmpty {
                    snoozedFooter
                }
            }
        }
    }

    private var visibleContexts: [DiagnosisContext] {
        contexts.filter { !snoozeStore.isSnoozed($0.diagnosis.title) }
    }

    private var snoozedContexts: [DiagnosisContext] {
        contexts.filter { snoozeStore.isSnoozed($0.diagnosis.title) }
    }

    // Narratives (highlighted "story" cards) always render — they carry
    // the *why* summary. Standalone rows are the individual raw signals
    // that can be trimmed when there are many.
    private var visibleNarratives: [DiagnosisContext] {
        visibleContexts.filter { $0.diagnosis.kind == .narrative }
    }

    private var visibleStandalone: [DiagnosisContext] {
        // Hide any standalone diagnosis whose title is subsumed by a
        // visible narrative — the narrative already tells that story
        // at a higher level, and stacking the redundant lower-level
        // row is what made the menu feel noisy.
        let subsumed = Set(visibleNarratives.flatMap(\.diagnosis.subsumes))
        return visibleContexts.filter {
            $0.diagnosis.kind == .standalone && !subsumed.contains($0.diagnosis.title)
        }
    }

    private var shownStandaloneRows: [DiagnosisContext] {
        if expandAllDiagnoses { return visibleStandalone }
        return Array(visibleStandalone.prefix(Self.standaloneVisibleCap))
    }

    private var hiddenStandaloneRows: [DiagnosisContext] {
        Array(visibleStandalone.dropFirst(Self.standaloneVisibleCap))
    }

    private var hasHiddenStandaloneRows: Bool {
        visibleStandalone.count > Self.standaloneVisibleCap
    }

    private var hiddenStandaloneLabel: String {
        if expandAllDiagnoses {
            return "Show fewer"
        }
        let count = hiddenStandaloneRows.count
        return count == 1 ? "1 more diagnosis" : "\(count) more diagnoses"
    }

    private var samplingState: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Sampling…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var normalState: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            // Careful not to over-claim: silence here means "none of
            // Whirr's rules fired," not "your machine is definitely
            // healthy." A user can have a sluggish machine that stays
            // below the thresholds; we'd rather train them to trust
            // the message when it's honest than pretend to be a
            // whole-system health check.
            Text("No diagnoses triggered right now.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Snoozed footer

    private var snoozedFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { showingSnoozed.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showingSnoozed ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text(showingSnoozed ? "Hide snoozed" : "Show \(snoozedContexts.count) snoozed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showingSnoozed {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(snoozedContexts) { context in
                        SnoozedRow(context: context, snoozeStore: snoozeStore)
                    }
                }
                .padding(.leading, 12)
            }
        }
    }
}

// MARK: - Narrative card

/// The highlighted "story" card. Narrative rules synthesize the multi-
/// signal explanation that the user wants to read first.
struct NarrativeCard: View {
    let context: DiagnosisContext
    let snoozeStore: SnoozeStore
    let compactMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(severityColor)
                    .accessibilityHidden(true)
                Text(context.diagnosis.title)
                    .font(.callout).bold()
                Spacer()
                if !compactMode {
                    DiagnosisMetaBadge(context: context)
                }
                SnoozeButton(title: context.diagnosis.title, snoozeStore: snoozeStore)
            }
            Text(context.diagnosis.detail)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(compactMode ? 6 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(severityColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(severityColor.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isSummaryElement)
    }

    private var severityColor: Color {
        switch context.diagnosis.severity {
        case .critical: return .red
        case .warning:  return .orange
        case .ok:       return .blue
        }
    }
}

// MARK: - Standalone row

/// A single standalone diagnosis — title + detail with a severity icon.
struct DiagnosisRow: View {
    let context: DiagnosisContext
    let snoozeStore: SnoozeStore
    let compactMode: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 14)
                .accessibilityLabel(severityLabel)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(context.diagnosis.title).font(.callout).bold()
                    Spacer()
                    if !compactMode {
                        DiagnosisMetaBadge(context: context)
                    }
                    SnoozeButton(title: context.diagnosis.title, snoozeStore: snoozeStore)
                }
                Text(context.diagnosis.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var severityLabel: String {
        switch context.diagnosis.severity {
        case .critical: return "Critical"
        case .warning:  return "Warning"
        case .ok:       return "Info"
        }
    }

    private var iconName: String {
        switch context.diagnosis.severity {
        case .critical: return "exclamationmark.triangle.fill"
        case .warning:  return "exclamationmark.circle.fill"
        case .ok:       return "info.circle.fill"
        }
    }

    private var iconColor: Color {
        switch context.diagnosis.severity {
        case .critical: return .red
        case .warning:  return .yellow
        case .ok:       return .blue
        }
    }
}

// MARK: - Meta badge (duration + trend)

/// Small "on for 4 min · stable" style pill next to each diagnosis.
/// Answers "how alarmed should I actually be?" at a glance — a warning
/// that just fired and is worsening reads differently than one that has
/// been on stably for an hour.
struct DiagnosisMetaBadge: View {
    let context: DiagnosisContext

    var body: some View {
        HStack(spacing: 4) {
            if let trendIcon {
                Image(systemName: trendIcon)
                    .font(.caption2)
                    .foregroundStyle(trendColor)
                    .accessibilityHidden(true)
            }
            Text(MenuFormat.duration(seconds: context.durationSeconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel(accessibilityLabel)
    }

    /// Only show a trend icon when the tracker has enough history for a
    /// meaningful comparison (worsening / improving). Stable is the
    /// default; we hide the arrow there to reduce noise.
    private var trendIcon: String? {
        switch context.trend {
        case .worsening: return "arrow.up.right"
        case .improving: return "arrow.down.right"
        case .stable:    return nil
        }
    }

    private var trendColor: Color {
        switch context.trend {
        case .worsening: return .red
        case .improving: return .green
        case .stable:    return .secondary
        }
    }

    private var accessibilityLabel: String {
        let duration = MenuFormat.duration(seconds: context.durationSeconds)
        let trend: String
        switch context.trend {
        case .worsening: trend = ", worsening"
        case .improving: trend = ", improving"
        case .stable:    trend = ""
        }
        return "on for \(duration)\(trend)"
    }
}

// MARK: - Snooze button

/// One-tap "snooze this diagnosis for an hour" affordance. Hidden by
/// default (subtle bell icon) so the row layout stays clean; expands on
/// hover. Popover offers duration options for users who want longer
/// snoozes than the default hour.
struct SnoozeButton: View {
    let title: String
    let snoozeStore: SnoozeStore
    @State private var showingMenu: Bool = false

    var body: some View {
        Menu {
            Button("Snooze for 1 hour")   { snoozeStore.snooze(title, duration: 3600) }
            Button("Snooze for 4 hours")  { snoozeStore.snooze(title, duration: 4 * 3600) }
            Button("Snooze until tomorrow") {
                snoozeStore.snooze(title, duration: 24 * 3600)
            }
        } label: {
            Image(systemName: "bell.slash")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Snooze \(title)")
        .help("Snooze this diagnosis")
    }
}

// MARK: - Snoozed row (compact)

/// Compact "Title · in 42 min" row shown inside the collapsed snoozed
/// footer. Tapping the row unsnoozes it.
struct SnoozedRow: View {
    let context: DiagnosisContext
    let snoozeStore: SnoozeStore

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(context.diagnosis.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let until = snoozeStore.snoozeExpiry(context.diagnosis.title) {
                Text(MenuFormat.timeUntil(until))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Button("Unsnooze") {
                snoozeStore.unsnooze(context.diagnosis.title)
            }
            .buttonStyle(.plain)
            .font(.caption2)
            .foregroundStyle(.blue)
            .accessibilityLabel("Unsnooze \(context.diagnosis.title)")
        }
    }
}
