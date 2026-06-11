#if DEBUG
import AVFoundation
import Foundation
import MLX
import MLXRandom

/// On-device smoke for the mlx-swift runtime and the Whisper pieces as they
/// land. Invoked from the Tuning sheet's debug section. The simulator is
/// documented to crash on any MLX op (insufficient `MTLGPUFamily`), so this
/// only does useful work on the iPhone 15 Pro Max. T1.1b-4 will replace the
/// per-section prints with a single end-to-end transcript of the bundled WAV.
nonisolated enum MLXSmoke {
    static func run() async {
        runMLXHello()
        runWhisperAudio()
        runWhisperModel()
        await runWhisperTranscribe()
        await runWhisperChunked()
        await runWhisperStore()
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
            let filters = try WhisperAudio.melFilters(nMels: 80, from: .bundled)
            print("  mel_80 filters shape       = \(filters.shape)")

            guard let flacURL = Bundle.main.url(forResource: "ls_test", withExtension: "flac") else {
                print("  ls_test.flac NOT FOUND in bundle — skipping end-to-end mel")
                return
            }

            let pcm = try WhisperAudio.loadPCM(url: flacURL)
            print("  ls_test.flac PCM samples   = \(pcm.count) (≈\(pcm.count / WhisperAudio.sampleRate)s @ 16 kHz)")

            let audio = WhisperAudio.padOrTrim(MLXArray(pcm))
            print("  pad-or-trim shape          = \(audio.shape)")

            let mel = try WhisperAudio.logMelSpectrogram(audio: audio, from: .bundled)
            eval(mel)
            let melMin: Float = mel.min().item()
            let melMax: Float = mel.max().item()
            print("  log-mel shape              = \(mel.shape)")
            print("  log-mel value range        = [\(melMin), \(melMax)]")
        } catch {
            print("  ERROR: \(error)")
        }
    }

    // MARK: - T1.1b-3 — model load + encoder

    private static func runWhisperModel() {
        print("[MLXSmoke] WhisperModel:")
        do {
            let loadStart = Date()
            let model = try WhisperModel.load(from: .bundled)
            let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)
            print("  load time                  = \(loadMs) ms")
            print("  dims.n_audio_state         = \(model.dims.n_audio_state)")
            print("  dims.n_audio_layer         = \(model.dims.n_audio_layer)")
            print("  dims.n_text_layer          = \(model.dims.n_text_layer)")
            print("  dims.n_vocab               = \(model.dims.n_vocab)")

            guard let flacURL = Bundle.main.url(forResource: "ls_test", withExtension: "flac") else {
                print("  ls_test.flac NOT FOUND — skipping encoder smoke")
                return
            }
            let pcm = try WhisperAudio.loadPCM(url: flacURL)
            let audio = WhisperAudio.padOrTrim(MLXArray(pcm))
            let mel = try WhisperAudio.logMelSpectrogram(audio: audio, from: .bundled)
            // Encoder expects [B, n_frames, n_mels]. Add a batch dim.
            let melBatch = expandedDimensions(mel, axis: 0)

            let encStart = Date()
            let features = model.embedAudio(melBatch)
            eval(features)
            let encMs = Int(Date().timeIntervalSince(encStart) * 1000)
            print("  audio features shape       = \(features.shape)")
            print("  encoder time               = \(encMs) ms")
        } catch {
            print("  ERROR: \(error)")
        }
    }

    // MARK: - T1.2d-1 — chunked transcribe over a >30 s clip

    /// Tiles the ~6 s test clip to ~36 s, writes it to a temp WAV, and runs it
    /// through the real `transcribe(_:options:)` path. Exercises the seek
    /// loop end-to-end on device: expect the sentence repeated ~6×, two
    /// decode windows, and a timestamp-guided restart between them (pre-T1.2d-1
    /// this clip would have transcribed only its first 30 s).
    private static func runWhisperChunked() async {
        print("[MLXSmoke] Chunked transcribe (tiled ~36 s):")
        guard let flacURL = Bundle.main.url(forResource: "ls_test", withExtension: "flac") else {
            print("  ls_test.flac NOT FOUND — skipping chunked transcribe")
            return
        }
        do {
            let pcm = try WhisperAudio.loadPCM(url: flacURL)
            var tiled: [Float] = []
            tiled.reserveCapacity(pcm.count * 6)
            for _ in 0..<6 { tiled.append(contentsOf: pcm) }

            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(WhisperAudio.sampleRate),
                channels: 1,
                interleaved: false
            ), let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(tiled.count)
            ) else {
                print("  ERROR: couldn't allocate tiled buffer")
                return
            }
            buffer.frameLength = AVAudioFrameCount(tiled.count)
            tiled.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress!, count: tiled.count)
            }

            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("mlxsmoke-tiled.wav")
            try? FileManager.default.removeItem(at: tmpURL)
            let file = try AVAudioFile(
                forWriting: tmpURL,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
            defer { try? FileManager.default.removeItem(at: tmpURL) }

            let transcriber = WhisperMLXTranscriber()
            let start = Date()
            let transcript = try await transcriber.transcribe(tmpURL, options: .whisperMLX)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            print("  tiled duration             = \(tiled.count / WhisperAudio.sampleRate) s")
            print("  chunked transcribe time    = \(ms) ms")
            print("  transcript                 = '\(transcript)'")
        } catch {
            print("  ERROR: \(error)")
        }
    }

    // MARK: - T1.2b — WhisperModelStore presence + asset staging

    /// Reports the on-disk state of the model bundle and exercises
    /// `stageBundledAssets()`. **Does not** kick off the 481 MB download —
    /// that runs from T1.2e's Settings "Download model" button once it lands.
    @MainActor
    private static func runWhisperStore() {
        print("[MLXSmoke] WhisperModelStore:")
        let store = WhisperModelStore()
        print("  modelDirectory             = \(store.modelDirectory.path)")
        print("  initial status             = \(store.status)")
        print("  download URL               = \(WhisperModelStore.downloadURL)")
        print("  expected SHA-256           = \(WhisperModelStore.expectedSHA256)")
        print("  expected size              = \(WhisperModelStore.expectedSize) bytes")

        do {
            try store.stageBundledAssets()
            print("  staged bundled assets      = config.json, gpt2.tiktoken, mel_filters.safetensors")
        } catch {
            print("  ERROR staging bundled assets: \(error)")
            return
        }

        if let contents = try? FileManager.default.contentsOfDirectory(atPath: store.modelDirectory.path) {
            print("  directory contents         = \(contents.sorted())")
        }
    }

    // MARK: - T1.1b-4 / T1.2c — end-to-end transcript, cold then cached

    /// Two passes through the *same* transcriber instance: the first pays
    /// model load + shader JIT, the second should show T1.2c's asset cache
    /// (expect the gap to be roughly the old per-call load cost).
    private static func runWhisperTranscribe() async {
        print("[MLXSmoke] WhisperMLXTranscriber:")
        guard let flacURL = Bundle.main.url(forResource: "ls_test", withExtension: "flac") else {
            print("  ls_test.flac NOT FOUND — skipping transcribe")
            return
        }
        let transcriber = WhisperMLXTranscriber()
        let options = TranscriptionOptions.whisperMLX
        do {
            let coldStart = Date()
            let transcript = try await transcriber.transcribe(flacURL, options: options)
            let coldMs = Int(Date().timeIntervalSince(coldStart) * 1000)
            print("  transcribe time (cold)     = \(coldMs) ms")
            print("  transcript                 = '\(transcript)'")

            let warmStart = Date()
            _ = try await transcriber.transcribe(flacURL, options: options)
            let warmMs = Int(Date().timeIntervalSince(warmStart) * 1000)
            print("  transcribe time (cached)   = \(warmMs) ms")
        } catch {
            print("  ERROR: \(error)")
        }
    }
}
#endif
