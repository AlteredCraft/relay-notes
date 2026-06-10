#if DEBUG
import Foundation
import MLX
import MLXRandom

/// On-device smoke for the mlx-swift runtime and the Whisper pieces as they
/// land. Invoked from the Tuning sheet's debug section. The simulator is
/// documented to crash on any MLX op (insufficient `MTLGPUFamily`), so this
/// only does useful work on the iPhone 15 Pro Max. T1.1b-4 will replace the
/// per-section prints with a single end-to-end transcript of the bundled WAV.
nonisolated enum MLXSmoke {
    static func run() {
        runMLXHello()
        runWhisperAudio()
    }

    // MARK: - T1.1a — mlx-swift runtime sanity

    private static func runMLXHello() {
        let info = GPU.deviceInfo()
        print("[MLXSmoke] Metal device:")
        print("  architecture                 = \(info.architecture)")
        print("  maxBufferSize                = \(info.maxBufferSize)")
        print("  maxRecommendedWorkingSetSize = \(info.maxRecommendedWorkingSetSize)")
        print("  memorySize                   = \(info.memorySize)")

        let a = MLXRandom.normal([4, 4])
        let b = MLXRandom.normal([4, 4])
        let c = a.matmul(b).sum()
        eval(c)
        let scalar: Float = c.item()
        print("[MLXSmoke] sum(N(0,1)[4,4] @ N(0,1)[4,4]) = \(scalar)")
    }

    // MARK: - T1.1b-1 — mel pipeline

    private static func runWhisperAudio() {
        print("[MLXSmoke] WhisperAudio mel pipeline:")
        do {
            let filters = try WhisperAudio.melFilters(nMels: 80)
            print("  mel_80 filters shape       = \(filters.shape)")

            guard let flacURL = Bundle.main.url(forResource: "ls_test", withExtension: "flac") else {
                print("  ls_test.flac NOT FOUND in bundle — skipping end-to-end mel")
                return
            }

            let pcm = try WhisperAudio.loadPCM(url: flacURL)
            print("  ls_test.flac PCM samples   = \(pcm.count) (≈\(pcm.count / WhisperAudio.sampleRate)s @ 16 kHz)")

            let audio = WhisperAudio.padOrTrim(MLXArray(pcm))
            print("  pad-or-trim shape          = \(audio.shape)")

            let mel = try WhisperAudio.logMelSpectrogram(audio: audio)
            eval(mel)
            let melMin: Float = mel.min().item()
            let melMax: Float = mel.max().item()
            print("  log-mel shape              = \(mel.shape)")
            print("  log-mel value range        = [\(melMin), \(melMax)]")
        } catch {
            print("  ERROR: \(error)")
        }
    }
}
#endif
