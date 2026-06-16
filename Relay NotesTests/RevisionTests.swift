import Foundation
import SwiftData
import Testing
@testable import Relay_Notes

/// R1.0 — pins the new append-only revision history on `Note`: the seeding
/// initializer, the `append*`/`revert` ops, the ≥1-revision/valid-active
/// invariant, `derivedFromID` lineage, and a SwiftData round-trip. These are
/// pure data ops (no MLX, no audio) so they run on every simulator test pass.
///
/// During the R1.0–R1.2 transition the legacy slots still exist (see `NoteTests`);
/// this suite exercises the revision system in parallel. The legacy slots — and
/// their tests — go away in R1.3 when `NoteDetailView` is the last consumer to
/// migrate.
@MainActor
struct RevisionTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Note.self, Revision.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    // MARK: - Seeding initializer + invariant

    @Test func seedingInitializerCreatesOneTranscriptionRevision() {
        let note = Note(audioFilename: "a.m4a", transcript: "hello", transcriptionModel: "Apple Speech")
        #expect(note.revisions.count == 1)
        let seed = note.activeRevision
        #expect(seed.kind == .transcription)
        #expect(seed.text == "hello")
        #expect(seed.modelLabel == "Apple Speech")
        #expect(seed.derivedFromID == nil)          // rooted at the audio
        #expect(note.displayText == "hello")
        #expect(note.activeRevisionID == seed.id)
    }

    @Test func invariantHoldsAfterConstruction() {
        let note = Note(audioFilename: "a.m4a", transcript: "x")
        #expect(note.revisions.count >= 1)
        #expect(note.revisions.contains { $0.id == note.activeRevisionID })
    }

    // MARK: - appendTranscription (re-transcribe)

    @Test func appendTranscriptionAddsRootedRevisionAndActivates() {
        let note = Note(audioFilename: "a.m4a", transcript: "apple text", transcriptionModel: "Apple Speech")
        let r1 = note.appendTranscription(text: "whisper text", modelLabel: "Whisper (small.en)")
        #expect(note.revisions.count == 2)
        #expect(note.activeRevisionID == r1.id)
        #expect(r1.kind == .transcription)
        #expect(r1.derivedFromID == nil)            // every transcription is rooted at the audio
        #expect(note.displayText == "whisper text")
        #expect(note.latestTranscription?.id == r1.id)
    }

    // MARK: - appendCleanup

    @Test func appendCleanupDerivesFromActiveAndActivates() {
        let note = Note(audioFilename: "a.m4a", transcript: "um hello wrld")
        let seedID = note.activeRevisionID
        let c = note.appendCleanup(text: "Hello, world.", modelLabel: "Gemma 4 E2B (MLX 4-bit)")
        #expect(note.revisions.count == 2)
        #expect(note.activeRevisionID == c.id)
        #expect(c.kind == .cleanup)
        #expect(c.derivedFromID == seedID)          // cleaned from the active transcription
        #expect(c.modelLabel == "Gemma 4 E2B (MLX 4-bit)")
        #expect(note.displayText == "Hello, world.")
    }

    // MARK: - appendEdit (Q1 semantics)

    @Test func appendEditFromTranscriptionStacksAndActivates() {
        let note = Note(audioFilename: "a.m4a", transcript: "hello wrld")
        let seedID = note.activeRevisionID
        let e = note.appendEdit("hello world")
        #expect(e != nil)
        #expect(note.activeRevision.kind == .edit)
        #expect(note.activeRevision.derivedFromID == seedID)
        #expect(note.displayText == "hello world")
    }

    @Test func appendEditEqualToActiveIsANoOp() {
        let note = Note(audioFilename: "a.m4a", transcript: "same")
        let before = note.revisions.count
        let result = note.appendEdit("same")
        #expect(result == nil)
        #expect(note.revisions.count == before)
        #expect(note.activeRevision.kind == .transcription)
    }

    /// Q1: editing back to the parent's text re-activates the parent (no redundant
    /// revision) — the new-model expression of "edit back to original ⇒ pristine".
    @Test func appendEditBackToParentReactivatesParent() {
        let note = Note(audioFilename: "a.m4a", transcript: "original")
        let seedID = note.activeRevisionID
        _ = note.appendEdit("changed")
        #expect(note.activeRevision.kind == .edit)
        let undo = note.appendEdit("original")
        #expect(undo == nil)                        // no new revision
        #expect(note.activeRevisionID == seedID)    // back on the transcription
        #expect(note.activeRevision.kind == .transcription)
        #expect(note.displayText == "original")
    }

    // MARK: - revert (pointer move, Q1)

    @Test func revertFromCleanupStepsToParentTranscription() {
        let note = Note(audioFilename: "a.m4a", transcript: "raw")
        let seedID = note.activeRevisionID
        _ = note.appendCleanup(text: "clean", modelLabel: "m")
        note.revert()
        #expect(note.activeRevisionID == seedID)
        #expect(note.displayText == "raw")
    }

    @Test func revertFromEditReturnsToTranscription() {
        let note = Note(audioFilename: "a.m4a", transcript: "machine")
        let seedID = note.activeRevisionID
        _ = note.appendEdit("hand edited")
        note.revert()
        #expect(note.activeRevisionID == seedID)
        #expect(note.activeRevision.kind == .transcription)
    }

    @Test func revertOnPristineTranscriptionIsANoOp() {
        let note = Note(audioFilename: "a.m4a", transcript: "machine")
        let seedID = note.activeRevisionID
        note.revert()
        #expect(note.activeRevisionID == seedID)
    }

    // MARK: - The §2 stale-cleanup bug is unrepresentable

    /// Clean → re-transcribe must NOT leave the stale cleaned text active. In the
    /// new model the fresh transcription becomes active; the prior cleanup lingers
    /// in history, still derived from the now-inactive transcription.
    @Test func reTranscribeAfterCleanupActivatesFreshTranscriptionNotStaleCleanup() {
        let note = Note(audioFilename: "a.m4a", transcript: "apple raw", transcriptionModel: "Apple Speech")
        let r0 = note.activeRevisionID
        let cleanup = note.appendCleanup(text: "Apple, cleaned.", modelLabel: "Gemma 4 E2B (MLX 4-bit)")
        let r1 = note.appendTranscription(text: "whisper raw", modelLabel: "Whisper (small.en)")
        #expect(note.activeRevisionID == r1.id)
        #expect(note.displayText == "whisper raw")          // NOT "Apple, cleaned."
        #expect(note.revisions.contains { $0.id == cleanup.id })  // history preserved
        #expect(cleanup.derivedFromID == r0)                // visibly stale (parent inactive)
    }

    // MARK: - latestTranscription tracks the most recent machine pass

    @Test func latestTranscriptionTracksMostRecentEvenAfterCleanup() {
        let note = Note(audioFilename: "a.m4a", transcript: "v1")
        let r1 = note.appendTranscription(text: "v2", modelLabel: "Whisper (small.en)")
        _ = note.appendCleanup(text: "v2 cleaned", modelLabel: "m")
        #expect(note.latestTranscription?.id == r1.id)
    }

    // MARK: - Persistence round-trip

    @Test func historyAndActivePointerPersistThroughInsertAndFetch() throws {
        let context = try makeContext()
        let note = Note(audioFilename: "a.m4a", transcript: "raw", transcriptionModel: "Apple Speech")
        _ = note.appendEdit("raw edited")
        _ = note.appendCleanup(text: "Raw, edited & cleaned.", modelLabel: "Gemma 4 E2B (MLX 4-bit)")
        context.insert(note)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Note>())
        #expect(fetched.count == 1)
        let n = try #require(fetched.first)
        #expect(n.revisions.count == 3)
        #expect(n.displayText == "Raw, edited & cleaned.")
        #expect(n.activeRevision.kind == .cleanup)
        #expect(n.orderedRevisions.map(\.kind) == [.transcription, .edit, .cleanup])
        // derivedFrom lineage survives the round-trip: cleanup ← edit ← transcription.
        let ordered = n.orderedRevisions
        #expect(ordered[1].derivedFromID == ordered[0].id)
        #expect(ordered[2].derivedFromID == ordered[1].id)
    }
}
