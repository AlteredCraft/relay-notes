import Foundation
import Observation

/// Runs LLM cleanup on a *saved* note's transcript — the cleanup analogue of
/// `ReTranscriber` (L2.4). Backs the "Clean up" action in `NoteDetailView`: load
/// the on-device model from its downloaded directory, clean the raw transcript,
/// and hand back a candidate for the user to accept or decline. Non-destructive —
/// the `Note` is untouched until the caller persists an accepted `Outcome`.
///
/// `@MainActor @Observable` so SwiftUI surfaces re-render off `isAvailable` (which
/// reaches through to the observed `CleanupModelStore.status`) — the "Clean up"
/// control flips to a "Set up cleanup model" link the moment the model is deleted,
/// and back when it's downloaded in the Tuning sheet.
@MainActor
@Observable
final class Cleaner {

    /// A cleaned candidate, surfaced for before/after review. Holding one does not
    /// change the `Note`; `NoteDetailView` writes it back only on "Accept".
    struct Outcome: Identifiable {
        let id = UUID()
        let raw: String
        let cleaned: String
        /// Provenance to persist on the `Note` if accepted (`Note.cleanupModel`).
        let modelLabel: String
    }

    /// MVP is one cleanup model; a picker (Gemma vs Qwen…) is the natural follow-up
    /// and would source this label from the selection.
    static let modelLabel = "Gemma 4 E2B (MLX 4-bit)"

    @ObservationIgnored private let store: CleanupModelStore
    @ObservationIgnored private var model: MLXLanguageModel?

    init(store: CleanupModelStore) {
        self.store = store
    }

    /// Whether cleanup can run right now — true only when the model is downloaded
    /// (`.ready`). The UI gates the action on this and offers a Tuning deep-link
    /// otherwise.
    var isAvailable: Bool { store.status == .ready }

    /// Clean `note`'s raw transcript and return a candidate. Non-destructive.
    /// Throws `.modelUnavailable` if the model isn't present (defensive — the UI
    /// gates on `isAvailable`, but the model could be deleted between gate and tap).
    func clean(_ note: Note) async throws -> Outcome {
        guard store.status == .ready else { throw LanguageModelError.modelUnavailable }
        let model = model ?? MLXLanguageModel(
            source: .directory(store.modelDirectory), modelDescription: Self.modelLabel)
        self.model = model
        let cleaned = try await model.clean(note.transcript)
        return Outcome(raw: note.transcript, cleaned: cleaned, modelLabel: Self.modelLabel)
    }

    /// Release the loaded model (~2.7 GB) + clear the MLX buffer pool. Called when
    /// the user leaves the note, so the cleanup model isn't resident while idle
    /// (§3.3 — it also shouldn't sit co-resident with an MLX transcriber; cleanup
    /// runs after finalize, never during recording).
    func evict() async {
        await model?.evict()
        model = nil
    }

    /// Generic, actionable — never leaks the underlying error (Projects/CLAUDE.md).
    nonisolated static func userMessage(for _: any Error) -> String {
        "Couldn't clean up this note. Please try again."
    }
}
