import SwiftUI
import WhirrCore

extension String {
    var sentenceCased: String { prefix(1).uppercased() + dropFirst() }
}

/// "How Whirr knows" and "Why it matters" for one story.
struct WhyPanel: View {
    let story: Story

    static func hasContent(_ story: Story) -> Bool {
        !story.evidence.isEmpty || story.impact != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !story.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("How Whirr knows").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(story.evidence.enumerated()), id: \.offset) { _, line in
                        Label {
                            Text(line).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "circle.fill").font(.system(size: 4))
                        }
                        .font(.callout)
                    }
                }
            }
            if let impact = story.impact {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Why it matters").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(impact).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background))
    }
}

/// Snooze / "normal for me" for every finding in a story at once.
struct QuietMenu: View {
    @Bindable var monitor: SystemMonitor
    let story: Story

    var body: some View {
        Menu {
            Button("Snooze for 1 hour") { story.titles.forEach { monitor.snoozeStore.snooze($0) } }
            // Muting is permanent, so only the story's own findings — never
            // system-wide ones that joined it this time.
            Button("This is normal for me") { story.muteTitles.forEach { monitor.snoozeStore.mute($0) } }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Quiet this")
    }
}

/// The action button, asking first when the action can't be undone.
struct StoryActionButton: View {
    @Bindable var monitor: SystemMonitor
    let story: Story
    var large = false
    @State private var confirming: SuggestedAction?

    var body: some View {
        if let action = story.action {
            Button(action.label) {
                if ActionText.needsConfirmation(action) { confirming = action } else { monitor.perform(action) }
            }
            .buttonStyle(.borderedProminent)
            .tint(story.isProblem ? story.headline.diagnosis.severity.tint : .accentColor)
            .controlSize(large ? .large : .small)
            .confirmationDialog(
                confirming?.label ?? "",
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                presenting: confirming
            ) { action in
                Button(action.label, role: .destructive) { monitor.perform(action) }
            } message: { Text(ActionText.confirmation(for: $0)) }
        }
    }
}

/// One story in a section list: title, because, action, Why?.
struct StoryCard: View {
    @Bindable var monitor: SystemMonitor
    let story: Story
    /// Inside the 2-minute gate: shown calm, like the answer card says.
    var isPending = false
    @State private var showWhy = false

    private var tint: Color { isPending ? .secondary : story.headline.displayTint }

    var body: some View {
        let d = story.headline.diagnosis
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isPending ? "eye" : story.headline.symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(d.title).font(.headline)
                    if isPending {
                        Text("Just started")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    } else if !story.isProblem {
                        Text("Note")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    Text(DurationText.words(seconds: story.durationSeconds))
                        .font(.caption).foregroundStyle(.tertiary)
                        .help("How long this has been going on")
                }
                Text(d.detail)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if showWhy { WhyPanel(story: story) }
                HStack(spacing: 8) {
                    StoryActionButton(monitor: monitor, story: story)
                    if WhyPanel.hasContent(story) {
                        Button(showWhy ? "Hide why" : "Why?") { showWhy.toggle() }
                            .buttonStyle(.link)
                    }
                    Spacer()
                    QuietMenu(monitor: monitor, story: story)
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(story.isProblem && !isPending ? 0.09 : 0.06))
        )
        .onAppear {
            if monitor.nav.focusedStoryID == story.id { showWhy = true; monitor.nav.focusedStoryID = nil }
        }
    }
}

/// The big answer at the top of Overview (area nil) and of each section.
struct AnswerCard: View {
    @Bindable var monitor: SystemMonitor
    let area: Diagnosis.Area?
    @State private var showWhy = false

    private var stories: [Story] {
        area.map { a in monitor.verdict.stories.filter { $0.area == a } } ?? monitor.verdict.stories
    }

    private var pending: [Story] {
        area.map { a in monitor.verdict.pendingStories.filter { $0.area == a } } ?? monitor.verdict.pendingStories
    }

    var body: some View {
        if !monitor.hasSampledYet {
            card(tint: .secondary, symbol: "hourglass", title: "Checking…", detail: nil)
        } else if let top = stories.first {
            card(tint: top.headline.diagnosis.severity.tint, symbol: top.headline.symbol,
                 title: StoryBuilder.sentence(stories) ?? top.phrase.sentenceCased, detail: top.because) {
                if showWhy { WhyPanel(story: top) }
                HStack(spacing: 10) {
                    StoryActionButton(monitor: monitor, story: top, large: true)
                    if WhyPanel.hasContent(top) {
                        Button(showWhy ? "Hide why" : "Why?") { showWhy.toggle() }.buttonStyle(.link)
                    }
                    Spacer()
                    Text("for \(DurationText.words(seconds: top.durationSeconds))")
                        .font(.caption).foregroundStyle(.secondary)
                    QuietMenu(monitor: monitor, story: top)
                }
            }
            .onAppear {
                if monitor.nav.focusedStoryID == top.id { showWhy = true; monitor.nav.focusedStoryID = nil }
            }
        } else if let first = pending.first {
            card(tint: .secondary, symbol: "eye", title: "Keeping an eye on something — \(first.phrase).",
                 detail: "Whirr waits a couple of minutes before raising a problem, so brief blips stay quiet.")
        } else if area != .mac && area != .developer && !monitor.net.connection.isMeasured {
            // No connection findings yet only means no checks yet.
            card(tint: .secondary, symbol: "hourglass",
                 title: area == nil ? "No problems with your Mac right now. Still checking your connection…"
                                    : "Checking your connection…",
                 detail: nil)
        } else {
            card(tint: .green, symbol: "checkmark.circle.fill", title: calmTitle, detail: nil)
        }
    }

    private var calmTitle: String {
        switch area {
        case nil: return "All good right now — no problems with your Mac or connection."
        case .mac?: return "No problems with your Mac right now."
        case .connection?: return "No connection problems right now."
        case .developer?: return "Nothing to report right now."
        }
    }

    private func card<Extra: View>(tint: Color, symbol: String, title: String, detail: String?,
                                   @ViewBuilder extra: () -> Extra = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: symbol).font(.title2).foregroundStyle(tint).accessibilityHidden(true)
                Text(title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if let detail {
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            extra()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }
}
