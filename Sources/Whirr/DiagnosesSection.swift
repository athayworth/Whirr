import SwiftUI
import WhirrCore

/// Diagnoses block: empty/sampling state on top, then narrative cards
/// (the "story") followed by standalone rows. The rules engine sorts
/// them; this view just renders.
struct DiagnosesSection: View {
    let hasSampledYet: Bool
    let diagnoses: [Diagnosis]

    var body: some View {
        if !hasSampledYet {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Sampling…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else if diagnoses.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("System running normally.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(diagnoses) { diagnosis in
                    if diagnosis.kind == .narrative {
                        NarrativeCard(diagnosis: diagnosis)
                    } else {
                        DiagnosisRow(diagnosis: diagnosis)
                    }
                }
            }
        }
    }
}

/// The highlighted "story" card. Narrative rules synthesize the multi-
/// signal explanation that the user wants to read first.
struct NarrativeCard: View {
    let diagnosis: Diagnosis

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(severityColor)
                    .accessibilityHidden(true)
                Text(diagnosis.title)
                    .font(.callout).bold()
            }
            Text(diagnosis.detail)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
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
        switch diagnosis.severity {
        case .critical: return .red
        case .warning:  return .orange
        case .ok:       return .blue
        }
    }
}

/// A single standalone diagnosis — title + detail with a severity icon.
struct DiagnosisRow: View {
    let diagnosis: Diagnosis

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 14)
                .accessibilityLabel(severityLabel)
            VStack(alignment: .leading, spacing: 2) {
                Text(diagnosis.title).font(.callout).bold()
                Text(diagnosis.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var severityLabel: String {
        switch diagnosis.severity {
        case .critical: return "Critical"
        case .warning:  return "Warning"
        case .ok:       return "Info"
        }
    }

    private var iconName: String {
        switch diagnosis.severity {
        case .critical: return "exclamationmark.triangle.fill"
        case .warning:  return "exclamationmark.circle.fill"
        case .ok:       return "info.circle.fill"
        }
    }

    private var iconColor: Color {
        switch diagnosis.severity {
        case .critical: return .red
        case .warning:  return .yellow
        case .ok:       return .blue
        }
    }
}
