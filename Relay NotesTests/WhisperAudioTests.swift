import AVFoundation
import Foundation
import Testing
@testable import Relay_Notes

#if !targetEnvironment(simulator)
import MLX
#endif

/// Shape + sanity tests for the mel pipeline (T1.1b-1).
///
/// **Why the simulator guard:** mlx-swift crashes on iOS Simulator because the
/// simulator's Metal GPU does not advertise the required `MTLGPUFamily`. The
/// constants test + AVFoundation PCM loader + error-throwing test run on the
/// simulator; everything that touches an `MLXArray` is gated behind
/// `#if !targetEnvironment(simulator)` and must be exercised via the
/// `#if DEBUG` MLX-smoke button on the iPhone 15 Pro Max instead.
///
/// Numerical correctness against the Python reference is deferred to T1.1b-3
/// once the model is wired up — an end-to-end transcript match is a stronger
/// signal than per-frame value comparison.
struct WhisperAudioTests {

    // MARK: - Simulator-safe (no MLX touched)

    @Test
    func constantsMatchPythonReference() {
        #expect(WhisperAudio.sampleRate == 16_000)
        #expect(WhisperAudio.nFFT == 400)
        #expect(WhisperAudio.hopLength == 160)
        #expect(WhisperAudio.nSamples == 480_000)
        #expect(WhisperAudio.nFrames == 3_000)
    }

    @Test
    func melFiltersRejectsUnsupportedBinCount() {
        // The precondition fires before any MLX call, so this is simulator-safe.
        #expect(throws: WhisperAudio.Error.self) {
            _ = try WhisperAudio.melFilters(nMels: 64, from: .bundled)
        }
    }

    @Test
    func locationDirectoryReturnsNilForMissingFile() {
        // Pure URL-resolution logic, no MLX.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-loc-\(UUID().uuidString)", isDirectory: true)
        let location = WhisperModelLocation.directory(tmp)
        #expect(location.fileURL(name: "config", ext: "json") == nil)
    }

    @Test
    func writtenWAVRoundTripsThroughLoadPCM() throws {
        // Pins the pattern MLXSmoke's chunked block uses (write PCM → read it
        // back with loadPCM). The writer must be deallocated before the read:
        // AVAudioFile finalizes the header on dealloc, and reading while the
        // writer is alive sees a zero-length file (device failure 2026-06-11).
        let sampleCount = 32_000  // 2 s @ 16 kHz
        let pcm = (0..<sampleCount).map { Float(sin(Double($0) * 0.01)) }

        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WhisperAudio.sampleRate),
            channels: 1,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(sampleCount)
        ))
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        pcm.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: sampleCount)
        }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wav-roundtrip-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        do {
            let file = try AVAudioFile(
                forWriting: tmpURL,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
        }  // writer deallocated here — header finalized

        let loaded = try WhisperAudio.loadPCM(url: tmpURL)
        #expect(loaded.count == sampleCount)
        // Spot-check a value away from the edges to confirm real content
        // round-tripped, not just the right-sized silence.
        #expect(abs(loaded[1_000] - pcm[1_000]) < 1e-4)
    }

    @Test
    func locationDirectoryReturnsURLWhenFileExists() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-loc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: file)

        let location = WhisperModelLocation.directory(tmp)
        let resolved = try #require(location.fileURL(name: "config", ext: "json"))
        #expect(resolved.path == file.path)
    }

    @Test
    func loadPCMFromBundledFLAC() throws {
        let url = try #require(Bundle.main.url(
            forResource: "ls_test",
            withExtension: "flac"
        ), "ls_test.flac must be bundled in the app")
        let pcm = try WhisperAudio.loadPCM(url: url)
        // LibriSpeech samples are typically a few seconds at 16 kHz —
        // confirm a non-trivial decode happened in the expected format.
        #expect(pcm.count > WhisperAudio.sampleRate)            // > 1 s
        #expect(pcm.count < WhisperAudio.sampleRate * 60)       // < 60 s sanity cap
    }

    // MARK: - Device-only (MLX-using)

    #if !targetEnvironment(simulator)

    @Test
    func padOrTrimPadsShortAudio() {
        let short = zeros([1_000], dtype: .float32)
        let padded = WhisperAudio.padOrTrim(short, length: 16_000)
        #expect(padded.shape == [16_000])
    }

    @Test
    func padOrTrimTrimsLongAudio() {
        let long = zeros([20_000], dtype: .float32)
        let trimmed = WhisperAudio.padOrTrim(long, length: 16_000)
        #expect(trimmed.shape == [16_000])
    }

    @Test
    func padOrTrimPassesExactLengthThrough() {
        let exact = zeros([16_000], dtype: .float32)
        let result = WhisperAudio.padOrTrim(exact, length: 16_000)
        #expect(result.shape == [16_000])
    }

    @Test
    func hanningWindowShapeAndExtremes() {
        let w = WhisperAudio.hanning(WhisperAudio.nFFT)
        #expect(w.shape == [WhisperAudio.nFFT])
        // First sample of a periodic Hann is 0.
        let first: Float = w[0].item()
        #expect(abs(first) < 1e-6)
        // Middle sample is 1.
        let middle: Float = w[WhisperAudio.nFFT / 2].item()
        #expect(abs(middle - 1.0) < 1e-6)
        // All values non-negative.
        let minVal: Float = w.min().item()
        #expect(minVal >= 0)
    }

    @Test
    func melFiltersLoadFromBundle() throws {
        let filters = try WhisperAudio.melFilters(nMels: 80, from: .bundled)
        #expect(filters.shape == [80, WhisperAudio.nFFT / 2 + 1])
    }

    @Test
    func logMelSpectrogramShapeFromZeroAudio() throws {
        let silence = zeros([WhisperAudio.nSamples], dtype: .float32)
        let mel = try WhisperAudio.logMelSpectrogram(audio: silence, from: .bundled)
        #expect(mel.shape == [WhisperAudio.nFrames, 80])
    }

    @Test
    func endToEndLogMelFromBundledFLAC() throws {
        let url = try #require(Bundle.main.url(
            forResource: "ls_test",
            withExtension: "flac"
        ))
        let pcm = try WhisperAudio.loadPCM(url: url)
        let audio = WhisperAudio.padOrTrim(MLXArray(pcm))
        let mel = try WhisperAudio.logMelSpectrogram(audio: audio, from: .bundled)
        #expect(mel.shape == [WhisperAudio.nFrames, 80])
        // Whisper's normalization is `(log10(mel) + 4) / 4` floored at `max - 8`.
        // That doesn't cap the absolute range — it bounds the *dynamic* range:
        // max − min ≤ 8 / 4 = 2 (within float precision). Validated on device
        // 2026-06-10 (max=1.573, min=-0.427 → diff exactly 2.0).
        let maxVal: Float = mel.max().item()
        let minVal: Float = mel.min().item()
        #expect(maxVal - minVal <= 2.0 + 1e-3)
    }

    #endif
}
