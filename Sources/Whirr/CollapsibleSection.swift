import SwiftUI

/// A section with a clickable header that shows/hides its content.
/// Collapse state persists across menu opens (and app restarts) via
/// `@AppStorage` keyed by the section's identifier — the user's choice
/// to hide "Top processes" won't unravel on the next tick.
///
/// Header layout: chevron (▶/▼) · title (small caption gray) · optional
/// trailing summary (right-aligned tertiary) — matches the visual
/// weight of the existing hand-rolled section headers (e.g., "Top
/// processes") so the transition doesn't feel jarring.
struct CollapsibleSection<Content: View>: View {
    let title: String
    /// Stable identifier used to key the persisted expand/collapse
    /// state. Two sections with the same id will share collapse state
    /// (rarely wanted; keep unique per section).
    let id: String
    /// Optional summary shown to the right of the title when collapsed.
    /// Lets us surface "5 apps" or "3 containers" without expanding —
    /// so the user gets some info even from a collapsed section.
    let summary: String?
    let defaultExpanded: Bool
    @ViewBuilder let content: () -> Content

    @AppStorage private var isExpanded: Bool

    init(
        title: String,
        id: String,
        summary: String? = nil,
        defaultExpanded: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.id = id
        self.summary = summary
        self.defaultExpanded = defaultExpanded
        self.content = content
        // Key format: matches other `preferences.*` keys so it shows up
        // grouped in `defaults read`. Namespaced by section id so
        // multiple sections don't collide.
        self._isExpanded = AppStorage(
            wrappedValue: defaultExpanded,
            "preferences.sectionExpanded.\(id)"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let summary, !isExpanded {
                        Text(summary)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(isExpanded ? "Tap to collapse" : "Tap to expand")

            if isExpanded {
                content()
            }
        }
    }
}
