import AVFoundation
import Foundation

/// Placeholder for the Tier-2 on-device transcriber. Real implementation arrives in T1.1
/// (`mlx-swift` + Whisper inference) and T1.2 (model download + recorder wiring).
/// For T1.0 this exists only so `TranscriberFactory` can resolve `.whisperMLX` without
/// special-casing the engine selection; both entry points throw `engineNotImplemented`.
nonisolated final class WhisperMLXTranscriber: Transcriber {
    init() {}

    func transcribe(_ audio: URL, options: TranscriptionOptions) async throws -> String {
        guard case .whisperMLX = options else {
            preconditionFailure("WhisperMLXTranscriber received non-whisperMLX options — factory and engine selection are out of sync")
        }
        throw TranscriptionError.engineNotImplemented("On-device Whisper isn't ready yet — switch to Apple Speech in Settings.")
    }

    func makeStreamingSession(options: TranscriptionOptions) async throws -> any TranscriptionSession {
        guard case .whisperMLX = options else {
            preconditionFailure("WhisperMLXTranscriber received non-whisperMLX options — factory and engine selection are out of sync")
        }
        throw TranscriptionError.engineNotImplemented("On-device Whisper isn't ready yet — switch to Apple Speech in Settings.")
    }
}
