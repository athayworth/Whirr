import SwiftUI
import WhirrCore

/// Top-of-menu "can I keep working right now?" card. This is the
/// primary read — the first thing the user sees when they open the
/// menu — so it gets the most visual weight of any section: bigger
/// icon, bigger headline, verdict-tinted background so the color
/// carries meaning even before the words.
///
/// `topHogFriendlyName` optionally overrides the raw process name in
/// the context sentence so a helper name like "Google Chrome Helper
/// (Renderer)" reads as "Google Chrome". Passed in by MenuBarView
/// which owns the ELI5 descriptor.
struct HeadroomSection: View {
    let hasSampledYet: Bool
    let headroom: HeadroomAssessment
    let topHogFriendlyName: String?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: iconName)
                .font(.title)
                .foregroundStyle(iconColor)
                .frame(width: 28, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(headroom.headline)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(displayContext)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Verdict-tinted background so the color carries the "how
        // worried should I be?" answer at a glance. Kept at 0.10 so
        // the section reads as an accent, not a solid banner — plays
        // nicely with the app's translucent menu bar chrome.
        .background(iconColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(iconColor.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isSummaryElement)
        .opacity(hasSampledYet ? 1 : 0.6)
    }

    /// Substring-swap the raw hog name for the ELI5 friendly name in
    /// the assessor's context sentence. Keeps HeadroomAssessor as the
    /// single source of truth for the wording — the UI just improves
    /// the name.
    private var displayContext: String {
        guard let friendly = topHogFriendlyName,
              let raw = headroom.topHogName,
              friendly != raw
        else { return headroom.context }
        return headroom.context.replacingOccurrences(of: raw, with: friendly)
    }

    private var iconName: String {
        switch headroom.verdict {
        case .comfortable: return "checkmark.circle.fill"
        case .tight:       return "exclamationmark.circle.fill"
        case .pressed:     return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch headroom.verdict {
        case .comfortable: return .green
        case .tight:       return .orange
        case .pressed:     return .red
        }
    }
}
