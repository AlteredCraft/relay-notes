import AVFoundation
import Foundation
import MLX

/// On-device Whisper transcriber. T1.1b-4 wires the file-based path end-to-end
/// (`PCM → mel → encoder → greedy decode → tokenizer decode`). The streaming
/// path still throws `engineNotImplemented` — recorder integration arrives in T1.2d.
///
/// **No instance caching yet.** Each `transcribe(_:options:)` call loads the model
/// and tokenizer fresh (~30 ms + JIT on first call after install). This keeps the
/// class trivially `Sendable` and avoids the actor-isolation gymnastics that
/// caching MLXArrays inside a `Sendable` `Transcriber` would require. T1.2c will
/// convert the class to an `actor` and add caching.
nonisolated final class WhisperMLXTranscriber: Transcriber {
    /// Where to load the model bundle from. T1.2a's surface change: instead of
    /// hardcoded `Bundle.main` lookups, callers can point the transcriber at
    /// a downloaded directory. Default stays `.bundled` so the dev path is
    /// unchanged until T1.2b's download manager wires in the directory case.
    let location: WhisperModelLocation

    init(location: WhisperModelLocation = .bundled) {
        self.location = location
    }

    func transcribe(_ audio: URL, options: TranscriptionOptions) async throws -> String {
        guard case .whisperMLX = options else {
            preconditionFailure(
                "WhisperMLXTranscriber received non-whisperMLX options — factory and engine selection are out of sync")
        }

        let pcm = try WhisperAudio.loadPCM(url: audio)
        let model = try WhisperModel.load(from: location)
        let tokenizer = try WhisperTokenizer(location: location)

        // Pad/trim to the 30-s chunk that the encoder expects, build the
        // log-mel, cast to fp16 to match the model's weight dtype (avoids
        // mid-graph promotion to fp32), and add a batch dim.
        let audioArr = WhisperAudio.padOrTrim(MLXArray(pcm))
        let mel = try WhisperAudio.logMelSpectrogram(audio: audioArr, from: location).asType(.float16)
        let melBatch = expandedDimensions(mel, axis: 0)
        let features = model.embedAudio(melBatch)
        eval(features)

        let ids = WhisperDecoding.greedyDecode(model: model, audioFeatures: features)
        return tokenizer.decode(ids)
    }

    func makeStreamingSession(options: TranscriptionOptions) async throws -> any TranscriptionSession {
        guard case .whisperMLX = options else {
            preconditionFailure(
                "WhisperMLXTranscriber received non-whisperMLX options — factory and engine selection are out of sync")
        }
        throw TranscriptionError.engineNotImplemented(
            "On-device Whisper streaming arrives in T1.2d — for now, Apple Speech is the streaming engine."
        )
    }
}
