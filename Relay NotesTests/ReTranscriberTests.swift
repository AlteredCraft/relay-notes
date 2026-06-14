import Foundation
import Testing
@testable import Relay_Notes

/// Tests for `ReTranscriber` — the "re-transcribe this note with another engine"
/// service backing the `NoteDetailView` menu. The audio recording is a
/// debug/tuning asset (issue #4); this service is what turns it into an
/// engine A/B.
///
/// All tests here are **simulator-safe**: they exercise the availability
/// gating, the pure option/label/error mappings, and disk-presence detection —
/// none allocate an `MLXArray` or run a decode. The actual `retranscribe(_:using:)`
/// execution is device territory (Apple needs auth + real audio; Whisper needs
/// MLX) and is covered by manual device validation / `MLXSmoke`, per the
/// project's MLX-on-simulator gating convention.
@MainActor
struct ReTranscriberTests {

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReTranscriberTests.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// A `ModelStores` whose Whisper store reports `.ready` by writing a
    /// placeholder weights file (pure disk-presence, no real 481 MB download / MLX
    /// load).
    private func makeReadyStores() -> (stores: ModelStores, dir: URL) {
        let dir = makeTempDirectory()
        let weights = dir.appendingPathComponent("weights.safetensors")
        try? Data("not-real-weights".utf8).write(to: weights)
        return (ModelStores(whisper: WhisperModelStore(modelDirectory: dir)), dir)
    }

    // MARK: - Availability gating
    //
    // The per-engine readiness *matrix* lives in `ModelStoresTests` (the single
    // source of truth since T2.3); here we only confirm `availableEngines`
    // reflects it.

    @Test func availableEnginesExcludesWhisperWhenModelMissing() {
        let dir = makeTempDirectory()
        defer { cleanup(dir) }
        let stores = ModelStores(whisper: WhisperModelStore(modelDirectory: dir))
        let service = ReTranscriber(factory: TranscriberFactory(), stores: stores)
        #expect(service.availableEngines == [.apple])
    }

    @Test func availableEnginesIncludesWhisperWhenModelReady() {
        let (stores, dir) = makeReadyStores()
        defer { cleanup(dir) }
        let service = ReTranscriber(factory: TranscriberFactory(), stores: stores)
        #expect(service.availableEngines == [.apple, .whisperMLX])
    }

    // MARK: - Option mapping

    @Test func optionsForAppleUsesEngineDefaults() {
        guard case let .apple(options) = ReTranscriber.options(for: .apple) else {
            Issue.record("Expected .apple options")
            return
        }
        #expect(options.preset == .transcription)
        #expect(options.contextualStrings.isEmpty)
    }

    @Test func optionsForWhisperIsWhisperMLX() {
        guard case .whisperMLX = ReTranscriber.options(for: .whisperMLX) else {
            Issue.record("Expected .whisperMLX options")
            return
        }
    }

    // MARK: - Provenance labels (must match the live streaming sessions)

    @Test func provenanceLabelForAppleMatchesSession() {
        // AppleSpeechSession.modelDescription returns TranscriptionEngine.apple.displayName.
        #expect(ReTranscriber.provenanceLabel(for: .apple) == TranscriptionEngine.apple.displayName)
        #expect(ReTranscriber.provenanceLabel(for: .apple) == "Apple Speech")
    }

    @Test func provenanceLabelForWhisperMatchesSession() {
        // WhisperStreamingSession.modelDescription returns WhisperMLXTranscriber.modelDescription.
        #expect(ReTranscriber.provenanceLabel(for: .whisperMLX) == WhisperMLXTranscriber.modelDescription)
        #expect(ReTranscriber.provenanceLabel(for: .whisperMLX) == "Whisper (small.en)")
    }

    // MARK: - Error → user message mapping (generic + actionable; no internals)

    @Test func userMessageForNoSpeechIsSpecific() {
        let message = ReTranscriber.userMessage(for: TranscriptionError.noSpeechDetected)
        #expect(message == "We couldn't find any speech in this recording.")
    }

    @Test func userMessageForOtherErrorsIsGeneric() {
        struct Boom: Error {}
        let message = ReTranscriber.userMessage(for: Boom())
        #expect(message == "Couldn't re-transcribe this note. Please try again.")
        // Must not leak the underlying error type.
        #expect(!message.contains("Boom"))
    }
}
