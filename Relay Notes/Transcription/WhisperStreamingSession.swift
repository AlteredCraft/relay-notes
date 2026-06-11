import AVFoundation
import Foundation
import Synchronization

/// T1.2d-2: the streaming session for on-device Whisper — accumulate PCM in
/// memory during `feed(_:)`, decode once at `finish()`.
///
/// **Emits zero partials by design.** Whisper has no incremental decode path
/// worth its cost for v1 (see transcription-tuning.md, "no streaming partials"
/// + issue #1 for the revisit triggers); the `updates` stream completes
/// without ever yielding. The recorder shows a placeholder instead of a live
/// transcript while Whisper is the engine (T1.2f).
///
/// **Memory bound:** raw Float32 PCM at 16 kHz is ~3.84 MB/min — ~115 MB for
/// a 30-minute note, comfortable on the 8 GB target device and freed promptly
/// at `finish()`/`cancel()`.
nonisolated final class WhisperStreamingSession: TranscriptionSession {

    /// 16 kHz mono Float32 — `LiveAudioEngine` converts mic-format tap
    /// buffers to this before yielding them, so `feed` receives exactly what
    /// the mel pipeline expects and no resampling happens at finish time.
    let audioFormat: AVAudioFormat?

    let updates: AsyncStream<String>

    private let updatesContinuation: AsyncStream<String>.Continuation
    private let transcriber: WhisperMLXTranscriber
    private let pcm = Mutex<[Float]>([])

    init(transcriber: WhisperMLXTranscriber) {
        self.transcriber = transcriber
        self.audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WhisperAudio.sampleRate),
            channels: 1,
            interleaved: false
        )
        (updates, updatesContinuation) = AsyncStream<String>.makeStream()
    }

    /// Appends the buffer's samples to the in-memory accumulator. Called from
    /// the recorder's feed loop; the `Mutex` makes it safe regardless of the
    /// caller's isolation.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: count))
        pcm.withLock { $0.append(contentsOf: samples) }
    }

    /// Runs the chunked transcribe over everything fed so far and returns the
    /// single final transcript. Mirrors `AppleSpeechSession`: an effectively
    /// empty transcript throws `noSpeechDetected` so the recorder shows its
    /// "didn't hear any speech" message instead of saving an empty note.
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
