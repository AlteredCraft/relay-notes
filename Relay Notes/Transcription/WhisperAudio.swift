// @preconcurrency: AVAudioConverter's input block is @Sendable in the SDK but
// is invoked synchronously during convert(to:) — the captures (file handle,
// reusable chunk buffer) never actually cross threads.
@preconcurrency import AVFoundation
import Foundation
import MLX

/// Whisper audio preprocessing — log-mel spectrogram + PCM loading.
///
/// Ports the relevant subset of
/// `ml-explore/mlx-examples/whisper/mlx_whisper/audio.py` to mlx-swift.
/// Constants and algorithm match the Python reference; the only swap is
/// `load_audio` (which shells out to `ffmpeg` in Python) → AVFoundation, since
/// iOS has no shell to call into. Output of ``logMelSpectrogram(audio:nMels:padding:)``
/// is `[nFrames, nMels]` in Whisper's convention — the encoder consumes it
/// transposed to `[1, nFrames, nMels]` (batch added) at use site.
nonisolated enum WhisperAudio {

    // MARK: - Constants

    static let sampleRate: Int = 16_000
    static let nFFT: Int = 400
    static let hopLength: Int = 160
    static let chunkLength: Int = 30
    static let nSamples: Int = chunkLength * sampleRate              // 480_000
    static let nFrames: Int = nSamples / hopLength                   // 3_000
    static let nSamplesPerToken: Int = hopLength * 2                 // 320
    static let framesPerSecond: Int = sampleRate / hopLength         // 100
    static let tokensPerSecond: Int = sampleRate / nSamplesPerToken  // 50

    enum Error: Swift.Error {
        case unsupportedNMels(Int)
        case melFiltersNotFound
        case melFiltersMissingKey(String)
        case audioFileOpenFailed(URL, any Swift.Error)
        case audioConversionFailed
        case audioBufferAllocationFailed
        case audioReadFailed(URL, any Swift.Error)
    }

    // MARK: - PCM loader

    /// Decodes any AVFoundation-readable audio file to 16 kHz mono Float32 PCM.
    /// Returned as a Swift `[Float]` so callers can wrap in an `MLXArray` on
    /// whichever stream they want — the audio file itself never touches MLX.
    ///
    /// Reads in a loop: `AVAudioFile.read(into:)` is not guaranteed to fill
    /// the buffer in one call (observed returning 256 frames short under
    /// parallel test load, 2026-06-11), so both paths keep reading until
    /// `framePosition` reaches `file.length`.
    static func loadPCM(url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw Error.audioFileOpenFailed(url, error)
        }

        let srcFormat = file.processingFormat
        guard let destFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw Error.audioConversionFailed
        }

        let chunkFrames: AVAudioFrameCount = 65_536
        guard let srcChunk = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: chunkFrames) else {
            throw Error.audioBufferAllocationFailed
        }

        /// Reads the next chunk into `srcChunk`. Returns false at EOF (or on
        /// a no-progress read, which guards against an infinite loop if the
        /// file is shorter than its header claims).
        func readNextChunk() throws -> Bool {
            guard file.framePosition < file.length else { return false }
            let before = file.framePosition
            do {
                try file.read(into: srcChunk)
            } catch {
                throw Error.audioReadFailed(url, error)
            }
            return file.framePosition > before
        }

        // Fast path: file is already at target rate/channel layout.
        if srcFormat.sampleRate == destFormat.sampleRate
            && srcFormat.channelCount == destFormat.channelCount
            && srcFormat.commonFormat == destFormat.commonFormat
        {
            var out: [Float] = []
            out.reserveCapacity(Int(file.length))
            while try readNextChunk() {
                out.append(contentsOf: extractFloats(srcChunk))
            }
            return out
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: destFormat) else {
            throw Error.audioConversionFailed
        }

        let ratio = destFormat.sampleRate / srcFormat.sampleRate
        guard let destChunk = AVAudioPCMBuffer(
            pcmFormat: destFormat,
            frameCapacity: AVAudioFrameCount(Double(chunkFrames) * ratio) + 1024
        ) else {
            throw Error.audioBufferAllocationFailed
        }

        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) * ratio) + 1024)
        var readError: (any Swift.Error)?

        while true {
            var converterError: NSError?
            let status = converter.convert(to: destChunk, error: &converterError) { _, inputStatus in
                do {
                    if try readNextChunk() {
                        inputStatus.pointee = .haveData
                        return srcChunk
                    }
                    inputStatus.pointee = .endOfStream
                    return nil
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            guard status != .error, converterError == nil else {
                throw Error.audioConversionFailed
            }
            out.append(contentsOf: extractFloats(destChunk))
            if status == .endOfStream { break }
        }
        return out
    }

    private static func extractFloats(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let count = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }

    // MARK: - Padding / trimming

    /// 1-D pad-with-zero-or-trim along the trailing (only) axis.
    static func padOrTrim(_ array: MLXArray, length: Int = nSamples) -> MLXArray {
        precondition(array.ndim == 1, "padOrTrim is 1D-only in this port")
        let current = array.shape[0]
        if current > length {
            return array[..<length]
        }
        if current < length {
            return padded(array, widths: [IntOrPair((0, length - current))])
        }
        return array
    }

    // MARK: - Mel filters

    /// Loads the precomputed mel filterbank from the given location.
    /// Shipped as `mel_filters.safetensors` (converted at staging time from
    /// `mlx-examples/whisper/mlx_whisper/assets/mel_filters.npz`).
    static func melFilters(nMels: Int = 80, from location: WhisperModelLocation) throws -> MLXArray {
        guard nMels == 80 || nMels == 128 else {
            throw Error.unsupportedNMels(nMels)
        }
        guard let url = location.fileURL(name: "mel_filters", ext: "safetensors") else {
            throw Error.melFiltersNotFound
        }
        let dict = try loadArrays(url: url)
        let key = "mel_\(nMels)"
        guard let filters = dict[key] else {
            throw Error.melFiltersMissingKey(key)
        }
        return filters
    }

    // MARK: - Hann window

    /// Periodic Hann window matching `np.hanning(size + 1)[:-1]`.
    /// w[k] = 0.5 − 0.5 · cos(2π·k / size), k ∈ [0, size).
    static func hanning(_ size: Int) -> MLXArray {
        let n = arange(size, dtype: .float32)
        let twoPi = Float(2.0 * .pi)
        let cosArg = (twoPi * n) / Float(size)
        return Float(0.5) - Float(0.5) * cos(cosArg)
    }

    // MARK: - STFT

    /// Short-time Fourier transform with reflect padding. Returns complex output
    /// of shape `[t, nperseg / 2 + 1]` where `t` is the number of frames.
    static func stft(
        _ x: MLXArray,
        window: MLXArray,
        nperseg: Int,
        noverlap: Int
    ) -> MLXArray {
        let nfft = nperseg
        let padding = nperseg / 2
        let xPadded = reflectPad1D(x, padding: padding)

        let totalLen = xPadded.shape[0]
        let t = (totalLen - nperseg + noverlap) / noverlap
        let frames = asStrided(xPadded, [t, nfft], strides: [noverlap, 1])
        return rfft(frames * window)
    }

    /// Reflect-pad a 1-D array by `padding` samples on each side, excluding the
    /// edge sample itself (matches numpy `mode='reflect'`).
    private static func reflectPad1D(_ x: MLXArray, padding: Int) -> MLXArray {
        precondition(x.ndim == 1)
        let n = x.shape[0]
        // prefix: [padding, padding-1, …, 1]
        let prefixIdx = arange(padding, 0, step: -1)
        // body: [0, 1, …, n-1]
        let bodyIdx = arange(n)
        // suffix: [n-2, n-3, …, n-1-padding]
        let suffixIdx = arange(n - 2, n - 2 - padding, step: -1)
        let allIdx = concatenated([prefixIdx, bodyIdx, suffixIdx], axis: 0)
        return x[allIdx]
    }

    // MARK: - log-mel spectrogram

    /// Log-mel spectrogram of 16 kHz mono PCM, normalized to roughly `[-1, 1]`.
    /// Output shape: `[nFrames, nMels]` where `nFrames = audioLength / hopLength`
    /// for a `chunkLength`-second clip (3000 frames for 30 s @ 16 kHz).
    /// Loads the filterbank from `location` on every call — callers that hold
    /// a cached filterbank (the T1.2c transcriber) use the `filters:` overload.
    static func logMelSpectrogram(
        audio: MLXArray,
        nMels: Int = 80,
        padding: Int = 0,
        from location: WhisperModelLocation
    ) throws -> MLXArray {
        let filters = try melFilters(nMels: nMels, from: location)
        return logMelSpectrogram(audio: audio, filters: filters, padding: padding)
    }

    /// Same computation with a preloaded filterbank (`[nMels, nFFT/2 + 1]`).
    static func logMelSpectrogram(
        audio: MLXArray,
        filters: MLXArray,
        padding: Int = 0
    ) -> MLXArray {
        var x = audio
        if padding > 0 {
            x = padded(x, widths: [IntOrPair((0, padding))])
        }
        let window = hanning(nFFT)
        let freqs = stft(x, window: window, nperseg: nFFT, noverlap: hopLength)

        // Drop the trailing frame (matches Python `freqs[:-1, :]`).
        let t = freqs.shape[0]
        let dropped = freqs[..<(t - 1)]

        // |X|^2
        let magnitudes = square(abs(dropped))

        let melSpec = magnitudes.matmul(filters.T)                   // [t-1, nMels]

        var logSpec = log10(maximum(melSpec, MLXArray(Float(1e-10))))
        let cap = logSpec.max() - Float(8.0)
        logSpec = maximum(logSpec, cap)
        return (logSpec + Float(4.0)) / Float(4.0)
    }
}
