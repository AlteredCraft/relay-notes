import SwiftUI

/// Settings group for **cleanup personalization** (plan.L2.md). Two free-text
/// fields — domains and terms/acronyms — that bias the on-device cleanup model
/// toward the user's world so it fixes domain words instead of mangling them.
/// Binds straight to the `cleanup` bundle on `Tunings`, which persists the edits.
///
/// Always shown (cleanup applies regardless of the transcription engine, so this
/// sits outside the Approach-C engine swap); the values only take effect when
/// "Clean up" runs on a note. The footer reassures that personalization never
/// becomes note content — the cardinal cleanup rule.
struct CleanupPersonalizationSection: View {
    @Bindable var tunings: Tunings

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Domains")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    "e.g. iOS development, on-device ML",
                    text: $tunings.cleanup.domains,
                    axis: .vertical
                )
                .lineLimit(1...3)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Terms & acronyms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    "e.g. MLX, Parakeet, AlteredCraft, SwiftData",
                    text: $tunings.cleanup.terms,
                    axis: .vertical
                )
                .lineLimit(1...5)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
        } header: {
            Text("Cleanup personalization")
        } footer: {
            Text("Help the cleanup model fix domain-specific words instead of mangling them. List the subjects your notes cover and the names, jargon, and acronyms it should spell correctly. Used only during \"Clean up\" — it's never added to your notes.")
        }
    }
}
