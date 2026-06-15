import Foundation
import SwiftData
import Testing
@testable import Relay_Notes

/// Pins the `Note.transcriptionModel` provenance field: it defaults to `nil`
/// (pre-existing notes carry no provenance) and round-trips through a SwiftData
/// container so the lightweight migration (new optional property) is exercised.
@MainActor
struct NoteTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Note.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test func transcriptionModelDefaultsToNil() {
        let note = Note(audioFilename: "a.m4a", transcript: "hello")
        #expect(note.transcriptionModel == nil)
    }

    @Test func transcriptionModelPersistsThroughInsertAndFetch() throws {
        let context = try makeContext()
        context.insert(Note(
            audioFilename: "a.m4a",
            transcript: "hello",
            transcriptionModel: "Whisper (small.en)"
        ))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Note>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.transcriptionModel == "Whisper (small.en)")
    }

    // MARK: - Transcript editing / revert (issue #5)

    @Test func newNoteIsPristine() {
        let note = Note(audioFilename: "a.m4a", transcript: "hello")
        #expect(note.originalTranscript == nil)
        #expect(note.isEdited == false)
    }

    @Test func firstEditStashesTheMachineBaseline() {
        let note = Note(audioFilename: "a.m4a", transcript: "hello wrld")
        note.applyEditedTranscript("hello world")
        #expect(note.transcript == "hello world")
        #expect(note.originalTranscript == "hello wrld")
        #expect(note.isEdited)
    }

    @Test func subsequentEditsKeepTheOriginalBaseline() {
        let note = Note(audioFilename: "a.m4a", transcript: "machine text")
        note.applyEditedTranscript("first edit")
        note.applyEditedTranscript("second edit")
        #expect(note.transcript == "second edit")
        #expect(note.originalTranscript == "machine text")
    }

    @Test func unchangedEditIsANoOp() {
        let note = Note(audioFilename: "a.m4a", transcript: "same")
        note.applyEditedTranscript("same")
        #expect(note.originalTranscript == nil)
        #expect(note.isEdited == false)
    }

    @Test func editingBackToTheOriginalReturnsToPristine() {
        let note = Note(audioFilename: "a.m4a", transcript: "original")
        note.applyEditedTranscript("changed")
        note.applyEditedTranscript("original")
        #expect(note.transcript == "original")
        #expect(note.originalTranscript == nil)
        #expect(note.isEdited == false)
    }

    @Test func revertRestoresOriginalAndClearsBaseline() {
        let note = Note(audioFilename: "a.m4a", transcript: "machine")
        note.applyEditedTranscript("hand edited")
        note.revertTranscript()
        #expect(note.transcript == "machine")
        #expect(note.originalTranscript == nil)
        #expect(note.isEdited == false)
    }

    @Test func revertOnPristineNoteIsANoOp() {
        let note = Note(audioFilename: "a.m4a", transcript: "machine")
        note.revertTranscript()
        #expect(note.transcript == "machine")
        #expect(note.originalTranscript == nil)
    }

    @Test func editedBaselinePersistsThroughInsertAndFetch() throws {
        let context = try makeContext()
        let note = Note(audioFilename: "a.m4a", transcript: "machine text")
        note.applyEditedTranscript("edited text")
        context.insert(note)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Note>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.transcript == "edited text")
        #expect(fetched.first?.originalTranscript == "machine text")
        #expect(fetched.first?.isEdited == true)
    }

    // MARK: - LLM cleanup (L2.4)

    @Test func newNoteIsNotCleaned() {
        let note = Note(audioFilename: "a.m4a", transcript: "hello")
        #expect(note.cleanedTranscript == nil)
        #expect(note.cleanupModel == nil)
        #expect(note.isCleaned == false)
    }

    @Test func applyCleanupStoresTextAndProvenanceNonDestructively() {
        let note = Note(audioFilename: "a.m4a", transcript: "um hello wrld")
        note.applyCleanup("Hello, world.", model: "Gemma 4 E2B (MLX 4-bit)")
        #expect(note.cleanedTranscript == "Hello, world.")
        #expect(note.cleanupModel == "Gemma 4 E2B (MLX 4-bit)")
        #expect(note.isCleaned)
        // Raw transcript is canonical — cleanup never overwrites it.
        #expect(note.transcript == "um hello wrld")
    }

    @Test func clearCleanupDropsCleanedCopyButKeepsRaw() {
        let note = Note(audioFilename: "a.m4a", transcript: "raw")
        note.applyCleanup("clean", model: "m")
        note.clearCleanup()
        #expect(note.cleanedTranscript == nil)
        #expect(note.cleanupModel == nil)
        #expect(note.isCleaned == false)
        #expect(note.transcript == "raw")
    }

    @Test func cleanupPersistsThroughInsertAndFetch() throws {
        let context = try makeContext()
        let note = Note(audioFilename: "a.m4a", transcript: "raw text")
        note.applyCleanup("clean text", model: "Gemma 4 E2B (MLX 4-bit)")
        context.insert(note)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Note>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.transcript == "raw text")
        #expect(fetched.first?.cleanedTranscript == "clean text")
        #expect(fetched.first?.cleanupModel == "Gemma 4 E2B (MLX 4-bit)")
        #expect(fetched.first?.isCleaned == true)
    }
}
