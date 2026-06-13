import Foundation
import MLX

/// Parakeet (FastConformer/TDT) mel front-end — the log-mel "featurizer" the
/// encoder consumes. Ports `senstella/parakeet-mlx`'s `audio.py::get_logmel`
/// (the Python *semantics oracle*) to mlx-swift, cross-checked against
/// `FluidInference/swift-parakeet-mlx`'s `AudioProcessing.swift`.
///
/// **This is NOT Whisper's mel** (`WhisperAudio.logMelSpectrogram`): different
/// `n_fft` (512 vs 400), mel count (128 vs 80), window (400-sample window
/// zero-padded to 512, vs Whisper's 400==`n_fft`), magnitude→power→log, and a
/// **per-feature** normalization (per-mel-bin z-score across time) instead of
/// Whisper's global `(logmel+4)/4` clamp. Only the genuinely generic STFT
/// primitives (`WhisperAudio.stft`, `WhisperAudio.hanning`) are shared — they
/// port the same numpy STFT and are already device-validated.
///
/// The Python and Swift references disagree on three details; this port resolves
/// each toward NeMo's training-time featurizer (see `plan.T2.md` §5.2):
///   1. **preemph 0.97** — applied (absent-key default; see `ParakeetConfig`),
///      not skipped as the FluidInference Optional read would.
///   2. **periodic Hann** (`np.hanning(N+1)[:-1]`, denominator `N`), via
///      `WhisperAudio.hanning` — not the symmetric `/(N-1)` form.
///   3. **L2 magnitude** (`|rfft|`) — matches NeMo's `torch.stft` magnitude;
///      the Python's `|re|+|im|` is an L1 approximation, the FluidInference
///      `abs(complex)` already L2.
///
/// Numerical correctness is only *confirmed* by the T2.1d end-to-end substring
/// gate (`ls_test.flac` → "openly shouldered the burden"); these three are the
/// suspects if it fails. T2.1b only validates shape + value range on device.
///
/// `nonisolated` (project default actor isolation is `MainActor`; MLX work is
/// isolation-neutral, like `WhisperAudio`).
nonisolated enum ParakeetAudio {

    /// Log-mel spectrogram for the FastConformer encoder.
    ///
    /// - Parameters:
    ///   - audio: 1-D PCM, 16 kHz mono (cast to Float32 internally for fidelity —
    ///     the `per_feature` z-score is precision-sensitive). Load via
    ///     `WhisperAudio.loadPCM` (engine-agnostic).
    ///   - config: the model's `preprocessor` block (`n_fft`, hop, mels, window,
    ///     `normalize`, `preemph`, `mag_power`).
    ///   - filters: the mel filterbank `[features, n_fft/2 + 1]` from
    ///     ``melFilterbank(config:)`` — pass a cached one; building it is a host
    ///     loop not worth repeating per call.
    /// - Returns: `[1, t, features]` Float32 (batch-first, as the encoder wants),
    ///   `t ≈ audioSamples / hop_length` (≈ 671 for the 6.7 s `ls_test.flac`).
    static func logMel(
        _ audio: MLXArray,
        config: ParakeetPreprocessConfig,
        filters: MLXArray
    ) -> MLXArray {
        var x = audio.asType(.float32)

        // `pad_to` is 0 for this checkpoint → no fixed-length padding. (NeMo pads
        // to a multiple here when configured; absent/0 means skip.)

        // 1. Pre-emphasis: x = [x₀, x₁−p·x₀, …, x_{n−1}−p·x_{n−2}] — a high-pass
        //    that flattens the spectral tilt the model was trained against.
        if let preemph = config.preemph {
            let n = x.shape[0]
            let head = x[0 ..< 1]
            let tail = x[1 ..< n] - preemph * x[0 ..< (n - 1)]
            x = MLX.concatenated([head, tail], axis: 0)
        }

        // 2. Periodic Hann of `win_length` (400), zero-padded on the right to
        //    `n_fft` (512). `WhisperAudio.stft` multiplies each `n_fft`-long frame
        //    by this window, so it must already be `n_fft` samples.
        let hann = WhisperAudio.hanning(config.winLength)
        let window: MLXArray = config.winLength == config.nFFT
            ? hann
            : MLX.padded(hann, widths: [IntOrPair((0, config.nFFT - config.winLength))])

        // 3. STFT (reflect-pad `n_fft/2`, frame, window, rfft) → `[t, n_fft/2+1]`
        //    complex. `noverlap:` is the hop (the stride), per WhisperAudio's API.
        //    Frame count is `n_fft`-based (= NeMo's `torch.stft(center=True)` count);
        //    the Python's `win_length`-based count is a latent quirk that can read
        //    past the buffer on some lengths — see plan.T2.md §5.2.
        let spectrum = WhisperAudio.stft(
            x, window: window, nperseg: config.nFFT, noverlap: config.hopLength)

        // 4. L2 magnitude, then power spectrum (`mag_power` = 2.0).
        let magnitude = MLX.abs(spectrum)
        let power = magnitude.pow(config.magPower)

        // 5. Mel projection + log. filters[mels, freqs] @ power[freqs, t] → [mels, t].
        let melSpectrum = MLX.matmul(filters.asType(power.dtype), power.transposed(axes: [1, 0]))
        let logMel = MLX.log(melSpectrum + 1e-5)

        // 6. Normalization. `per_feature` (this model) z-scores each mel bin across
        //    time; otherwise a global z-score. `std` is population (ddof 0), matching
        //    numpy/mlx and NeMo. `+1e-5` guards silent bins.
        let normalized: MLXArray
        if config.normalize == "per_feature" {
            let mean = logMel.mean(axes: [1], keepDims: true)
            let sd = std(logMel, axes: [1], keepDims: true)
            normalized = (logMel - mean) / (sd + 1e-5)
        } else {
            let mean = logMel.mean()
            let sd = std(logMel)
            normalized = (logMel - mean) / (sd + 1e-5)
        }

        // 7. [mels, t] → [t, mels] → [1, t, mels].
        return normalized.transposed(axes: [1, 0]).expandedDimensions(axis: 0)
    }

    // MARK: - Mel filterbank (Slaney, librosa-exact)

    /// Triangular mel filterbank `[features, n_fft/2 + 1]` equivalent to
    /// `librosa.filters.mel(sr, n_fft, n_mels, fmin=0, fmax=sr/2, htk=False,
    /// norm="slaney")` — exactly what the Python oracle builds.
    ///
    /// **Two independent "Slaney" choices**, both needed to match the oracle:
    ///   - the **Slaney mel *scale*** (piecewise linear-below-1 kHz / log-above),
    ///     from librosa's default `htk=False`. The FluidInference Swift port uses
    ///     the **HTK** scale (`2595·log10(1+f/700)`) — a latent mismatch we avoid.
    ///   - the **Slaney area *norm*** (`2/(mel_f[i+2]−mel_f[i])`), from
    ///     `norm="slaney"`.
    ///
    /// Built on the host in `Double` once (a ~128×257 loop — negligible, and it
    /// dodges the per-element `.item()` GPU syncs the reference filterbank incurs),
    /// then wrapped as one Float32 `MLXArray`.
    static func melFilterbank(config: ParakeetPreprocessConfig) -> MLXArray {
        melFilterbank(
            sampleRate: config.sampleRate,
            nFFT: config.nFFT,
            nMels: config.features,
            fMin: 0,
            fMax: Double(config.sampleRate) / 2)
    }

    static func melFilterbank(
        sampleRate: Int, nFFT: Int, nMels: Int, fMin: Double, fMax: Double
    ) -> MLXArray {
        let nFreqs = nFFT / 2 + 1

        // FFT bin center frequencies: linspace(0, sr/2, nFreqs) ≡ k·sr/n_fft.
        var fftFreqs = [Double](repeating: 0, count: nFreqs)
        for k in 0 ..< nFreqs { fftFreqs[k] = Double(k) * Double(sampleRate) / Double(nFFT) }

        // n_mels+2 band edges, equally spaced on the Slaney mel scale.
        let melMin = hzToMelSlaney(fMin)
        let melMax = hzToMelSlaney(fMax)
        var melF = [Double](repeating: 0, count: nMels + 2)
        for i in 0 ..< (nMels + 2) {
            let mel = melMin + (melMax - melMin) * Double(i) / Double(nMels + 1)
            melF[i] = melToHzSlaney(mel)
        }

        // Triangular filters with Slaney area normalization. Row-major [nMels, nFreqs].
        var weights = [Float](repeating: 0, count: nMels * nFreqs)
        for m in 0 ..< nMels {
            let lower = melF[m]
            let center = melF[m + 1]
            let upper = melF[m + 2]
            let leftDen = center - lower
            let rightDen = upper - center
            let enorm = 2.0 / (upper - lower)  // Slaney area norm
            for k in 0 ..< nFreqs {
                let f = fftFreqs[k]
                let rising = (f - lower) / leftDen
                let falling = (upper - f) / rightDen
                let w = max(0.0, min(rising, falling)) * enorm
                weights[m * nFreqs + k] = Float(w)
            }
        }
        return MLXArray(weights, [nMels, nFreqs])
    }

    /// Slaney (`htk=False`) Hz→mel: linear (slope `3/200`) below 1 kHz, log above.
    private static func hzToMelSlaney(_ hz: Double) -> Double {
        let fSp = 200.0 / 3.0
        let minLogHz = 1000.0
        let minLogMel = minLogHz / fSp            // 15.0
        let logstep = Foundation.log(6.4) / 27.0
        if hz >= minLogHz {
            return minLogMel + Foundation.log(hz / minLogHz) / logstep
        }
        return hz / fSp
    }

    /// Slaney (`htk=False`) mel→Hz — inverse of ``hzToMelSlaney(_:)``.
    private static func melToHzSlaney(_ mel: Double) -> Double {
        let fSp = 200.0 / 3.0
        let minLogHz = 1000.0
        let minLogMel = minLogHz / fSp            // 15.0
        let logstep = Foundation.log(6.4) / 27.0
        if mel >= minLogMel {
            return minLogHz * Foundation.exp(logstep * (mel - minLogMel))
        }
        return fSp * mel
    }
}
