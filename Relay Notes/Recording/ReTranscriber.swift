import Foundation
import Observation

/// Re-runs transcription on a *saved* note's audio with a chosen engine — the
/// feature that makes the persisted recording a debug/tuning asset rather than
/// dead weight (issue #4). Backs the "Re-transcribe" menu in `NoteDetailView`,
/// letting you run the same audio through the other engine and compare (the
/// Apple-vs-Whisper A/B flagged in `planning/notes.md` § B).
///
/// This is the first real consumer of the file-based
/// `Transcriber.transcribe(_:options:)` path — until now only `MLXSmoke`
/// exercised it. The streaming path (`makeStreamingSession`) stays the live
/// recorder's; this one re-decodes a finished file.
///
/// Shares the recorder's `TranscriberFactory` (constructed once in
/// `ContentView`) so a re-transcribe reuses the already-loaded ~481 MB Whisper
/// model instead of loading a second copy. Calls serialize through
/// `WhisperMLXTranscriber`'s actor, which is the right behavior for the
/// single-model GPU engine.
@MainActor
@Observable
final class ReTranscriber {

    /// A candidate transcript produced by a re-run, surfaced to the user to
    /// compare against the current one and optionally keep. Non-destructive:
    /// holding an `Outcome` does not change the `Note` — `NoteDetailView` writes
    /// it back only on an explicit "Replace".
    struct Outcome: Identifiable {
        let id = UUID()
        let engine: TranscriptionEngine
        let transcript: String
        /// Provenance label to persist on the `Note` if kept — identical to what
        /// a fresh recording with this engine would store.
        let modelLabel: String
    }

    @ObservationIgnored
    private let factory: TranscriberFactory
    private let stores: ModelStores

    init(factory: TranscriberFactory, stores: ModelStores) {
        self.factory = factory
        self.stores = stores
    }

    /// Engines available to re-transcribe into right now. Apple is always
    /// available; a model-backed engine only when its model is downloaded — the
    /// same engine-availability invariant the recorder enforces
    /// (`Tunings.reconcileEngineAvailability`). Reads through `ModelStores` to the
    /// observed store statuses, so a SwiftUI menu built from this updates when a
    /// model is downloaded/deleted.
    var availableEngines: [TranscriptionEngine] {
        TranscriptionEngine.allCases.filter { stores.isReady($0) }
    }

    /// Whether the note's audio still exists on disk. Older notes whose file was
    /// removed — and the seeded `SampleNotes`, which never had one — can't be
    /// re-transcribed; the caller hides the control rather than failing on tap.
    func audioExists(for note: Note) -> Bool {
        FileManager.default.fileExists(atPath: note.audioURL.path)
    }

    /// Re-decodes the note's saved audio with `engine` and returns the candidate.
    /// Non-destructive — the `Note` is untouched; the caller decides whether to
    /// keep the result.
    func retranscribe(_ note: Note, using engine: TranscriptionEngine) async throws -> Outcome {
        let transcriber = factory.transcriber(for: engine)
        let transcript = try await transcriber.transcribe(note.audioURL, options: Self.options(for: engine))
        return Outcome(
            engine: engine,
            transcript: transcript,
            modelLabel: Self.provenanceLabel(for: engine)
        )
    }

    // MARK: - Pure helpers

    /// Each engine's *default* options — not the user's live `Tunings`. A re-run
    /// is an A/B against a clean baseline, so it shouldn't depend on whatever
    /// preset/biasing happens to be set in Settings right now. `@MainActor`
    /// (the project default) because `AppleSpeechOptions`'s init is.
    static func options(for engine: TranscriptionEngine) -> TranscriptionOptions {
        switch engine {
        case .apple: return .apple(AppleSpeechOptions())
        case .whisperMLX: return .whisperMLX
        }
    }

    /// The label persisted on the `Note` when a candidate is kept. Sourced from
    /// the same constants the live streaming sessions report
    /// (`AppleSpeechSession` / `WhisperStreamingSession`) so a re-transcribed
    /// note is indistinguishable from a freshly recorded one. `@MainActor`
    /// because `TranscriptionEngine.displayName` is.
    static func provenanceLabel(for engine: TranscriptionEngine) -> String {
        switch engine {
        case .apple: return TranscriptionEngine.apple.displayName
        case .whisperMLX: return WhisperMLXTranscriber.modelDescription
        }
    }

    /// Generic, actionable user message — never leaks the underlying error.
    nonisolated static func userMessage(for error: any Error) -> String {
        if case TranscriptionError.noSpeechDetected = error {
            return "We couldn't find any speech in this recording."
        }
        return "Couldn't re-transcribe this note. Please try again."
    }
}
