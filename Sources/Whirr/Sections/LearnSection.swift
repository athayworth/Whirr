import SwiftUI
import WhirrCore

/// Small ⓘ next to a label. Hover shows the one-line explanation; click
/// opens the fuller one.
struct InfoButton: View {
    let term: Glossary.Term
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(term.short)
        .accessibilityLabel("About \(term.title)")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            TermExplanation(term: term)
                .padding(16)
                .frame(width: 340)
        }
    }
}

/// A label with an ⓘ after it.
struct LabelWithInfo: View {
    let text: String
    let term: Glossary.Term
    var font: Font = .body

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(font)
            InfoButton(term: term)
        }
    }
}

private struct TermExplanation: View {
    let term: Glossary.Term

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(term.title).font(.headline)
            Text(term.short).fixedSize(horizontal: false, vertical: true)
            Text(term.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("All terms are in Learn, in the sidebar.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// Every term, grouped, for reading at leisure.
struct LearnSection: View {
    var body: some View {
        SectionPage(title: "Learn") {
            Text("What Whirr's words and numbers mean. Hover over or click any ⓘ elsewhere in Whirr to see one of these in place.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Glossary.Group.allCases, id: \.self) { group in
                SectionHeader(title: group.title)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(group.terms.enumerated()), id: \.element) { index, term in
                        if index > 0 { Divider() }
                        TermExplanation(term: term)
                            .padding(14)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
            }
        }
    }
}
