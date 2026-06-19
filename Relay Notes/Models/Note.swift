import Foundation
import SwiftData

@Model
final class Note {
    var id: UUID
    var createdAt: Date
    var audioFilename: String
    var title: String?

    /// Append-only revision history (R1). The note's text lives here — every
    /// transformation (re-transcribe, edit, cleanup) appends a `Revision` rather
    /// than mutating in place. Cascade-deleted with the note. See
    /// `planning/plan.R1.md`.
    @Relationship(deleteRule: .cascade, inverse: \Revision.note)
    var revisions: [Revision] = []

    /// The revision the prod UI shows / shares. Invariant: always resolves to a
    /// member of `revisions` (the seeding initializer guarantees ≥1 revision and a
    /// valid pointer; every op preserves it).
    var activeRevisionID: UUID = UUID()

    /// Creates a note seeded with its initial machine transcription as the first
    /// `.transcription` revision, so the ≥1-revision / valid-active invariant holds
    /// by construction. `transcript`/`transcriptionModel` are the seed's text +
    /// provenance — they are *not* stored as separate fields.
    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        audioFilename: String,
        transcript: String,
        title: String? = nil,
        transcriptionModel: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.audioFilename = audioFilename
        self.title = title
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
        let trimmed = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
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
    /// history, falling back to the most recent revision. The fallback is
    /// unreachable given the ≥1-revision invariant established at init; the
    /// `preconditionFailure` surfaces a corrupted store (e.g. a bad migration)
    /// with a diagnostic instead of a bare force-unwrap.
    var activeRevision: Revision {
        if let active = revisions.first(where: { $0.id == activeRevisionID }) {
            return active
        }
        guard let latest = orderedRevisions.last else {
            preconditionFailure("Note has no revisions; the ≥1-revision invariant was violated")
        }
        return latest
    }

    /// The current displayed (and shared) text — the active revision's text.
    var displayText: String { activeRevision.text }

    /// Whether the displayed text is a user hand-edit.
    var isEdited: Bool { activeRevision.kind == .edit }

    /// Whether the displayed text is an LLM-cleaned revision.
    var isCleaned: Bool { activeRevision.kind == .cleanup }

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
