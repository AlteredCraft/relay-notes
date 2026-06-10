import AVFoundation
import Foundation
import MLX

/// On-device Whisper transcriber. T1.1b-4 wires the file-based path end-to-end
/// (`PCM → mel → encoder → greedy decode → tokenizer decode`). The streaming
/// path still throws `engineNotImplemented` — recorder integration arrives in T1.2.
///
/// **No instance caching yet.** Each `transcribe(_:options:)` call loads the model
/// and tokenizer fresh (~30 ms + JIT on first call after install). This keeps the
/// class trivially `Sendable` and avoids the actor-isolation gymnastics that
/// caching MLXArrays inside a `Sendable` `Transcriber` would require. T1.2 will
/// revisit caching when recorder UX makes the per-call load cost matter.
nonisolated final class WhisperMLXTranscriber: Transcriber {
    init() {}

    func transcribe(_ audio: URL, options: TranscriptionOptions) async throws -> String {
        guard case .whisperMLX = options else {
            preconditionFailure(
                "WhisperMLXTranscriber received non-whisperMLX options — factory and engine selection are out of sync")
        }

        let pcm = try WhisperAudio.loadPCM(url: audio)
        let model = try WhisperModel.loadFromBundle()
        let tokenizer = try WhisperTokenizer()

        // Pad/trim to the 30-s chunk that the encoder expects, build the
        // log-mel, cast to fp16 to match the model's weight dtype (avoids
        // mid-graph promotion to fp32), and add a batch dim.
        let audioArr = WhisperAudio.padOrTrim(MLXArray(pcm))
        let mel = try WhisperAudio.logMelSpectrogram(audio: audioArr).asType(.float16)
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
            "On-device Whisper streaming arrives in T1.2 — for now, Apple Speech is the streaming engine."
        )
    }
}
