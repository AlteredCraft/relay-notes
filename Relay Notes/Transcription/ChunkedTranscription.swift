import Foundation

/// The fixed audio-window contract a transcription model imposes on its input.
///
/// Whisper's encoder takes exactly 30 s of 16 kHz audio (480 000 samples —
/// baked into the architecture as 1500 positional embeddings). A future local
/// model with different constraints adapts by supplying its own `AudioWindow`;
/// the chunking driver below never changes.
nonisolated struct AudioWindow: Sendable, Equatable {
    let sampleRate: Int
    let samplesPerWindow: Int

    func samples(forSeconds seconds: Double) -> Int {
        Int((seconds * Double(sampleRate)).rounded())
    }

    static let whisper = AudioWindow(
        sampleRate: WhisperAudio.sampleRate,
        samplesPerWindow: WhisperAudio.nSamples
    )
}

/// How far the driver should move after decoding one window.
///
/// `.toTime(seconds)` is the timestamp-guided seek from the Whisper reference:
/// the decode reports where (within the window) its last *complete* segment
/// ended, and the next window restarts exactly there — so no words are cut at
/// arbitrary 30-s boundaries. `.fullWindow` means the window was fully
/// consumed (trailing silence, no usable timestamps, or skipped as silence).
nonisolated enum WindowAdvance: Sendable, Equatable {
    case fullWindow
    case toTime(Double)
}

nonisolated struct WindowDecodeResult: Sendable, Equatable {
    let text: String
    let advance: WindowAdvance
}

/// Model-agnostic long-audio transcription: walk the PCM in model-sized
/// windows, delegating per-window transcription to `decodeWindow` and
/// advancing by whatever boundary it reports. Ported from the seek loop in
/// `mlx_whisper/transcribe.py`, with the model-specific parts (mel slicing,
/// timestamp-token parsing, silence detection) pushed behind the closure.
nonisolated enum ChunkedTranscription {

    /// Runs `decodeWindow` over consecutive windows of `pcm` and joins the
    /// per-window texts with single spaces (empty texts — skipped silent
    /// windows — are dropped). The closure receives a slice of at most
    /// `window.samplesPerWindow` samples; the final window may be shorter.
    static func run(
        pcm: [Float],
        window: AudioWindow,
        decodeWindow: (ArraySlice<Float>) throws -> WindowDecodeResult
    ) rethrows -> String {
        var pieces: [String] = []
        var seek = 0
        while seek < pcm.count {
            let end = min(seek + window.samplesPerWindow, pcm.count)
            let result = try decodeWindow(pcm[seek..<end])

            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                pieces.append(text)
            }

            switch result.advance {
            case .fullWindow:
                seek += window.samplesPerWindow
            case .toTime(let seconds):
                let delta = window.samples(forSeconds: seconds)
                // A non-positive boundary would stall the loop — the Whisper
                // timestamp rules guarantee forward progress, but guard here
                // so a misbehaving decode degrades to plain windowing instead
                // of hanging.
                seek += delta > 0 ? delta : window.samplesPerWindow
            }
        }
        return pieces.joined(separator: " ")
    }
}
