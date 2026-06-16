import Foundation
import SwiftData
import Testing
@testable import Relay_Notes

/// Note-level behavior that isn't about the revision history itself (that's
/// `RevisionTests`). After R1.2 the legacy text slots + their helpers are gone;
/// what's left here is `displayTitle`, which derives from the active revision's
/// text via `displayText`.
@MainActor
struct NoteTests {

    @Test func explicitTitleWins() {
        let note = Note(audioFilename: "a.m4a", transcript: "some spoken words", title: "My Title")
        #expect(note.displayTitle == "My Title")
    }

    @Test func whitespaceTitleFallsBackToText() {
        let note = Note(audioFilename: "a.m4a", transcript: "hello there", title: "   ")
        #expect(note.displayTitle == "hello there")
    }

    @Test func emptyTextIsUntitled() {
        let note = Note(audioFilename: "a.m4a", transcript: "")
        #expect(note.displayTitle == "Untitled")
    }

    @Test func shortTextBecomesTheTitle() {
        let note = Note(audioFilename: "a.m4a", transcript: "one two three")
        #expect(note.displayTitle == "one two three")
    }

    @Test func longTextTruncatesToSixWords() {
        let note = Note(audioFilename: "a.m4a", transcript: "one two three four five six seven eight")
        #expect(note.displayTitle == "one two three four five six…")
    }

    /// `displayTitle` tracks the *active* revision, not the original transcription:
    /// after a cleanup the title reflects the cleaned text.
    @Test func titleTracksActiveRevision() {
        let note = Note(audioFilename: "a.m4a", transcript: "um so like the thing")
        note.appendCleanup(text: "The thing.", modelLabel: "m")
        #expect(note.displayTitle == "The thing.")
    }
}
