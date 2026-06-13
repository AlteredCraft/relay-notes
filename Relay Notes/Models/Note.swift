import Foundation
import SwiftData

@Model
final class Note {
    var id: UUID
    var createdAt: Date
    var audioFilename: String
    var transcript: String
    var title: String?

    /// Human-readable provenance label of the engine/model that produced this
    /// transcript, e.g. "Apple Speech" or "Whisper (small.en)". Optional and
    /// `nil` for notes recorded before provenance capture existed (no backfill
    /// — we never stored it historically); the detail view hides the row when
    /// absent. Captured at save time from `TranscriptionSession.modelDescription`.
    var transcriptionModel: String?

    /// The verbatim machine transcription, stashed the first time the user
    /// hand-edits `transcript` so the edit can be reverted. `nil` means the note
    /// is *pristine* — never edited (the common case, and the value for every
    /// note recorded before editing existed — no backfill, same lightweight
    /// migration as `transcriptionModel`). `transcript` always holds the current
    /// displayed text; this is only ever the pre-edit baseline. Two states by
    /// design — original and current — not a full history (issue #5).
    var originalTranscript: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        audioFilename: String,
        transcript: String,
        title: String? = nil,
        transcriptionModel: String? = nil,
        originalTranscript: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.audioFilename = audioFilename
        self.transcript = transcript
        self.title = title
        self.transcriptionModel = transcriptionModel
        self.originalTranscript = originalTranscript
    }
}

extension Note {
    var audioURL: URL {
        URL.documentsDirectory.appending(path: audioFilename)
    }

    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Untitled" }
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        if parts.count <= 6 {
            return parts.joined(separator: " ")
        }
        return parts.prefix(6).joined(separator: " ") + "…"
    }

    func deleteWithAudio(in context: ModelContext) {
        try? FileManager.default.removeItem(at: audioURL)
        context.delete(self)
        try? context.save()
    }

    /// Whether the transcript has been hand-edited away from the machine
    /// baseline — true exactly when `originalTranscript` holds the pre-edit text.
    var isEdited: Bool { originalTranscript != nil }

    /// Apply a hand-edited transcript. On the *first* divergence it stashes the
    /// current (machine) transcript into `originalTranscript` so the edit can be
    /// reverted; later edits keep that same baseline. A no-op when `newText`
    /// matches the current transcript, and if an edit lands back exactly on the
    /// original the note returns to pristine (`originalTranscript` cleared) so it
    /// stops advertising itself as edited. Caller persists via the model context.
    func applyEditedTranscript(_ newText: String) {
        guard newText != transcript else { return }
        if originalTranscript == nil {
            originalTranscript = transcript
        }
        transcript = newText
        if newText == originalTranscript {
            originalTranscript = nil
        }
    }

    /// Restore the original machine transcript and drop the edited copy, returning
    /// the note to its pristine, never-edited state. No-op when not edited.
    func revertTranscript() {
        guard let originalTranscript else { return }
        transcript = originalTranscript
        self.originalTranscript = nil
    }
}
