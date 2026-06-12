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
}
