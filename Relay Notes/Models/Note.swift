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

    /// The LLM-cleaned transcript (de-filler, punctuation, light structure), or
    /// `nil` when the note has never been cleaned (the default, and the value for
    /// every note from before cleanup existed — same lightweight additive migration
    /// as `transcriptionModel`/`originalTranscript`). **Non-destructive:** `transcript`
    /// always stays the canonical raw text; cleanup never overwrites it (L2.4).
    var cleanedTranscript: String?

    /// Provenance of the model that produced `cleanedTranscript`, e.g.
    /// "Gemma 4 E2B (MLX 4-bit)". `nil` when not cleaned. Mirrors `transcriptionModel`.
    var cleanupModel: String?

    /// Append-only revision history (R1). The note's text lives here, not in the
    /// legacy slots above — every transformation (re-transcribe, edit, cleanup)
    /// appends a `Revision`. Cascade-deleted with the note. **Transitional (R1.0):**
    /// the legacy slots are still populated/read by consumers not yet migrated;
    /// they go away in R1.3. See `planning/plan.R1.md`.
    @Relationship(deleteRule: .cascade, inverse: \Revision.note)
    var revisions: [Revision] = []

    /// The revision the prod UI shows / shares. Invariant: always resolves to a
    /// member of `revisions` (the seeding initializer guarantees ≥1 revision and a
    /// valid pointer; every op preserves it).
    var activeRevisionID: UUID = UUID()

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        audioFilename: String,
        transcript: String,
        title: String? = nil,
        transcriptionModel: String? = nil,
        originalTranscript: String? = nil,
        cleanedTranscript: String? = nil,
        cleanupModel: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.audioFilename = audioFilename
        self.transcript = transcript
        self.title = title
        self.transcriptionModel = transcriptionModel
        self.originalTranscript = originalTranscript
        self.cleanedTranscript = cleanedTranscript
        self.cleanupModel = cleanupModel
        // Seed the history with the initial machine transcription so the
        // ≥1-revision / valid-active invariant holds by construction.
        let seed = Revision(
            createdAt: createdAt,
            kind: .transcription,
            text: transcript,
            modelLabel: transcriptionModel
        )
        self.revisions = [seed]
        self.activeRevisionID = seed.id
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

    /// Whether an LLM-cleaned version exists.
    var isCleaned: Bool { cleanedTranscript != nil }

    /// Store the accepted cleaned transcript + its model provenance. Non-destructive
    /// — `transcript` (the raw text) is untouched. Caller persists via the context.
    func applyCleanup(_ text: String, model: String?) {
        cleanedTranscript = text
        cleanupModel = model
    }

    /// Drop the cleaned version (back to raw-only). No-op when not cleaned.
    func clearCleanup() {
        cleanedTranscript = nil
        cleanupModel = nil
    }
}

// MARK: - Revision history (R1)

extension Note {
    /// History in chronological order. SwiftData to-many relationships are
    /// unordered, so we sort by `createdAt`; ops stamp strictly-increasing
    /// timestamps (`nextTimestamp`) so the order is deterministic.
    var orderedRevisions: [Revision] {
        revisions.sorted { $0.createdAt < $1.createdAt }
    }

    /// The revision the prod UI shows. Resolves `activeRevisionID` against the
    /// history; the fallback is unreachable given the ≥1-revision invariant but
    /// keeps this non-optional and crash-free.
    var activeRevision: Revision {
        revisions.first { $0.id == activeRevisionID } ?? orderedRevisions.last!
    }

    /// The current displayed (and shared) text — the active revision's text.
    var displayText: String { activeRevision.text }

    /// The most recent machine transcription — the re-transcribe target and the
    /// "original" for a prod compare. `nil` only if the invariant is violated.
    var latestTranscription: Revision? {
        orderedRevisions.last { $0.kind == .transcription }
    }

    /// Append a fresh machine transcription (initial or re-transcribe) and make it
    /// active. Rooted at the audio, so `derivedFromID` is `nil`.
    @discardableResult
    func appendTranscription(text: String, modelLabel: String?) -> Revision {
        append(.init(createdAt: nextTimestamp(), kind: .transcription,
                     text: text, modelLabel: modelLabel))
    }

    /// Append an LLM-cleaned revision derived from the active revision, and make it
    /// active.
    @discardableResult
    func appendCleanup(text: String, modelLabel: String?) -> Revision {
        append(.init(createdAt: nextTimestamp(), kind: .cleanup, text: text,
                     modelLabel: modelLabel, derivedFromID: activeRevisionID))
    }

    /// Apply a hand-edited text. Returns the new revision, or `nil` when no
    /// revision was created:
    /// - `text` equals the active revision ⇒ no-op (nothing changed).
    /// - `text` equals the active revision's *parent* ⇒ the edit was undone back to
    ///   where it came from; re-activate the parent (Q1) rather than stack a
    ///   redundant revision. This is the new-model "edit back to original ⇒
    ///   pristine" behavior.
    /// Otherwise append an `.edit` derived from the active revision and activate it.
    @discardableResult
    func appendEdit(_ text: String) -> Revision? {
        let active = activeRevision
        if text == active.text { return nil }
        if let parentID = active.derivedFromID,
           let parent = revisions.first(where: { $0.id == parentID }),
           parent.text == text {
            activeRevisionID = parent.id
            return nil
        }
        return append(.init(createdAt: nextTimestamp(), kind: .edit, text: text,
                            derivedFromID: active.id))
    }

    /// Move the active pointer one step up the derivation chain — to the active
    /// revision's parent, or to the latest transcription when it's rooted. A pure
    /// pointer move: history is preserved, nothing is deleted (Q1). No-op when
    /// already on the latest transcription.
    func revert() {
        let active = activeRevision
        if let parentID = active.derivedFromID,
           revisions.contains(where: { $0.id == parentID }) {
            activeRevisionID = parentID
        } else if let transcription = latestTranscription {
            activeRevisionID = transcription.id
        }
    }

    // MARK: Internals

    @discardableResult
    private func append(_ revision: Revision) -> Revision {
        revisions.append(revision)
        activeRevisionID = revision.id
        return revision
    }

    /// A timestamp strictly greater than every existing revision's, so chronological
    /// order is deterministic even when appends happen within the same instant
    /// (real wall-clock when it's already ahead, nudged forward only on a tie).
    private func nextTimestamp() -> Date {
        let latest = revisions.map(\.createdAt).max() ?? .distantPast
        let now = Date.now
        return now > latest ? now : latest.addingTimeInterval(0.001)
    }
}
