import AVFoundation
import Foundation
import Synchronization

/// Streaming session for on-device Parakeet (T2.5) — accumulate PCM in memory
/// during `feed(_:)`, decode once at `finish()`. Mirrors `WhisperStreamingSession`
/// (the non-streaming MLX session shape the recorder already supports via the
/// placeholder UX).
///
/// **Emits zero partials by design.** Parakeet's TDT decode is a single end-of-
/// recording pass (no incremental decode ported for v1); the `updates` stream
/// completes without yielding, and `RecorderView` shows the placeholder card
/// instead of a perpetually-blank live transcript (T1.2f, `emitsLivePartials`).
///
/// **Memory bound:** raw Float32 PCM at 16 kHz is ~3.84 MB/min — ~115 MB for a
/// 30-minute note, freed promptly at `finish()`/`cancel()`. (The transcribe itself
/// chunks long audio so the encoder's O(T²) attention and activation footprint
/// stay bounded — see `ParakeetTDTModel.transcribeChunked`.)
nonisolated final class ParakeetStreamingSession: TranscriptionSession {

    /// 16 kHz mono Float32 — `LiveAudioEngine` converts mic-format tap buffers to
    /// this before yielding, so `feed` receives exactly what the mel pipeline
    /// expects and no resampling happens at finish time. (Parakeet's featurizer,
    /// like Whisper's, is 16 kHz; `WhisperAudio.sampleRate` is the shared rate.)
    let audioFormat: AVAudioFormat?

    let updates: AsyncStream<String>

    /// Zero partials by design (see the type doc).
    let emitsLivePartials = false

    var modelDescription: String { ParakeetMLXTranscriber.modelDescription }

    private let updatesContinuation: AsyncStream<String>.Continuation
    private let transcriber: ParakeetMLXTranscriber
    private let pcm = Mutex<[Float]>([])

    init(transcriber: ParakeetMLXTranscriber) {
        self.transcriber = transcriber
        self.audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WhisperAudio.sampleRate),
            channels: 1,
            interleaved: false
        )
        (updates, updatesContinuation) = AsyncStream<String>.makeStream()
    }

    /// Appends the buffer's samples to the in-memory accumulator. Called from the
    /// recorder's feed loop; the `Mutex` makes it safe regardless of the caller's
    /// isolation.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: count))
        pcm.withLock { $0.append(contentsOf: samples) }
    }

    /// Runs the chunked transcribe over everything fed so far and returns the
    /// single final transcript. An effectively empty transcript throws
    /// `noSpeechDetected` so the recorder shows its "didn't hear any speech"
    /// message instead of saving an empty note (mirrors the other sessions).
    func finish() async throws -> String {
        defer { updatesContinuation.finish() }
        let samples = pcm.withLock { buffered in
            let copy = buffered
            buffered.removeAll(keepingCapacity: false)
            return copy
        }
        let transcript = try await transcriber.transcribePCM(samples)
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TranscriptionError.noSpeechDetected
        }
        return transcript
    }

    func cancel() async {
        pcm.withLock { $0.removeAll(keepingCapacity: false) }
        updatesContinuation.finish()
    }

    /// Test seam — sample count accumulated so far.
    var bufferedSampleCount: Int {
        pcm.withLock { $0.count }
    }
}
