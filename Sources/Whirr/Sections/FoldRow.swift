import SwiftUI
import WhirrCore

/// A fold-open row for detail that isn't the answer. Whirr remembers
/// whether each one was left open.
struct FoldRow<Content: View>: View {
    let title: String
    var summary: String?
    var term: Glossary.Term?
    @ViewBuilder let content: Content
    @AppStorage private var isOpen: Bool

    init(_ title: String, summary: String? = nil, term: Glossary.Term? = nil, key: String,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.summary = summary
        self.term = term
        self.content = content()
        _isOpen = AppStorage(wrappedValue: false, "fold.\(key)")
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isOpen) {
            content.padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                if let term { InfoButton(term: term) }
                if let summary {
                    Text("— \(summary)").foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Three small facts under a section's answer.
struct KeyFacts: View {
    let facts: [(label: String, value: String, term: Glossary.Term?)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
            GridRow {
                ForEach(Array(facts.enumerated()), id: \.offset) { _, f in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 3) {
                            Text(f.label).font(.caption).foregroundStyle(.secondary)
                            if let term = f.term { InfoButton(term: term).font(.caption) }
                        }
                        Text(f.value).font(.body.monospacedDigit())
                    }
                }
            }
        }
    }
}
