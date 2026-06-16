import SwiftUI

/// A generic side-by-side "before vs after" sheet for two revisions of a note —
/// no diff engine, just two labeled text blocks and a primary/secondary action
/// (R1.2). Consolidates the former `ReTranscribeOutcomeSheet` and
/// `CleanupOutcomeSheet`, which were the same view with different labels, and
/// will also back "compare any two revisions" in the debug history surface (R1.4).
/// Non-destructive — it only renders; the caller's actions decide what persists.
struct RevisionComparisonView: View {
    /// One labeled column. `emphasized` tints the label (used for the candidate /
    /// "new" side, as the old sheets did).
    struct Side {
        let label: String
        let text: String
        var emphasized: Bool = false
    }

    /// A toolbar action: its button title and what it does.
    struct Action {
        let title: String
        let perform: () -> Void
    }

    let title: String
    let left: Side
    let right: Side
    /// Trailing, semibold — the commit (Replace / Accept).
    let primary: Action
    /// Leading — the dismiss (Keep original / Discard).
    let secondary: Action

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section(left)
                    Divider()
                    section(right)
                }
                .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(secondary.title, action: secondary.perform)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(primary.title, action: primary.perform)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ side: Side) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(side.label)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(side.emphasized ? Color.accentColor : .secondary)
            Text(side.text.isEmpty ? "—" : side.text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}
