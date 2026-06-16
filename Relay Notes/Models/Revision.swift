import Foundation
import SwiftData

/// What produced a `Revision`'s text. One case per transformation the app can
/// apply to a note. New enrichment stages (categorize, summarize, title…) add a
/// case here, not a new field on `Note` (R1 — see `planning/plan.R1.md`).
enum RevisionKind: String, Codable {
    /// Machine speech-to-text — the initial auto pass AND any later re-transcribe.
    /// Always rooted at the audio (`derivedFromID == nil`).
    case transcription
    /// A user hand-edit. The user is the author, so `modelLabel` is `nil`.
    case edit
    /// LLM cleanup (L2) — de-filler, punctuation, light structure.
    case cleanup
    // future: categorization, summary, title, translation…
}

/// One entry in a `Note`'s append-only revision history. The text is **immutable
/// once created** — transformations append a new `Revision` rather than rewriting
/// an existing one. `derivedFromID` records the revision this was produced from
/// (`nil` ⇒ rooted at the audio, true of every `.transcription`); it's stored for
/// provenance and staleness, not traversed as a tree (R1 keeps the history flat —
/// see `planning/plan.R1.md` §3.2).
@Model
final class Revision {
    var id: UUID
    var createdAt: Date
    var kind: RevisionKind
    var text: String
    /// Provenance of the model that produced `text` — e.g. "Apple Speech",
    /// "Whisper (small.en)", "Gemma 4 E2B (MLX 4-bit)". `nil` for `.edit`.
    var modelLabel: String?
    /// The revision this was produced from. `nil` ⇒ rooted at the audio.
    var derivedFromID: UUID?
    /// Inverse of `Note.revisions`; the owning note (cascade-deleted with it).
    var note: Note?

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        kind: RevisionKind,
        text: String,
        modelLabel: String? = nil,
        derivedFromID: UUID? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.text = text
        self.modelLabel = modelLabel
        self.derivedFromID = derivedFromID
    }
}
