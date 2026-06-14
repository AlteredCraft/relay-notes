#if DEBUG
import AVFoundation
import Foundation
import MLX
import MLXRandom
import UIKit

/// On-device smoke for the mlx-swift runtime and the Whisper pieces as they
/// land. Invoked from the Tuning sheet's debug section. The simulator is
/// documented to crash on any MLX op (insufficient `MTLGPUFamily`), so this
/// only does useful work on the iPhone 15 Pro Max. T1.1b-4 will replace the
/// per-section prints with a single end-to-end transcript of the bundled WAV.
nonisolated enum MLXSmoke {
    /// The bundled `ls_test.flac` is a fixed LibriSpeech clip, so its decode is
    /// deterministic. Asserting a stable substring turns the transcribe smokes
    /// into a pass/fail check (T1.3 "assert substring") instead of an eyeball.
    /// Matched case-insensitively against the decoded text.
    private static let expectedSubstring = "openly shouldered the burden"

    static func run() async {
        runMLXHello()
        runWhisperAudio()
        // Weights are download-only now (no longer bundled). Resolve the
        // downloaded model once; the model-loading sections skip with a hint
        // when it isn't present. Run the Settings "Download model" flow first.
        let modelLocation = await resolveDownloadedModelLocation()
        runWhisperModel(modelLocation)
        await runWhisperTranscribe(modelLocation)
        await runWhisperChunked(modelLocation)
        await runMeasurements(modelLocation)
        await runWhisperStore()
    }

    /// The on-disk directory of the downloaded model, or `nil` when it hasn't
    /// been downloaded yet. Weights live only in Application Support now (the
    /// 481 MB `weights.safetensors` is no longer copied into the app bundle).
    @MainActor
    private static func resolveDownloadedModelLocation() -> ModelLocation? {
        let store = WhisperModelStore()
        return store.status == .ready ? store.location : nil
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

    private static func runWhisperModel(_ location: ModelLocation?) {
        print("[MLXSmoke] WhisperModel:")
        guard let location else {
            print("  model not downloaded — download it from Settings, then re-run. Skipping.")
            return
        }
        do {
            let loadStart = Date()
            let model = try WhisperModel.load(from: location)
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
    private static func runWhisperChunked(_ location: ModelLocation?) async {
        print("[MLXSmoke] Chunked transcribe (tiled ~36 s):")
        guard let location else {
            print("  model not downloaded — download it from Settings, then re-run. Skipping.")
            return
        }
        guard let flacURL = Bundle.main.url(forResource: "ls_test", withExtension: "flac") else {
            print("  ls_test.flac NOT FOUND — skipping chunked transcribe")
            return
        }
        do {
            let pcm = try WhisperAudio.loadPCM(url: flacURL)
            var tiled: [Float] = []
            tiled.reserveCapacity(pcm.count * 6)
            for _ in 0..<6 { tiled.append(contentsOf: pcm) }

            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("mlxsmoke-tiled.wav")
            try? FileManager.default.removeItem(at: tmpURL)
            try writeWAV(pcm: tiled, to: tmpURL)
            defer { try? FileManager.default.removeItem(at: tmpURL) }

            let transcriber = WhisperMLXTranscriber(fallbackLocation: location)
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

    // MARK: - T1.3 — load / decode / peak-memory / battery measurements

    /// Decodes the bundled fixture tiled to 1-min and 5-min lengths, capturing
    /// decode wall-time, peak `phys_footprint`, and a coarse battery delta on
    /// the iPhone 15 Pro Max. Produces the T1.3 measurement table in one run;
    /// the numbers land in `notes.md` § "T1 measurements" + a Decisions-log row.
    ///
    /// The transcript is repetitive by construction (one ~6.7 s clip tiled) —
    /// this measures decode *cost vs length*, not accuracy (accuracy is the
    /// substring check in `runWhisperTranscribe`).
    private static func runMeasurements(_ location: ModelLocation?) async {
        print("[MLXSmoke] T1.3 measurements:")
        guard let location else {
            print("  model not downloaded — download it from Settings, then re-run. Skipping.")
            return
        }
        guard let flacURL = Bundle.main.url(forResource: "ls_test", withExtension: "flac") else {
            print("  ls_test.flac NOT FOUND — skipping measurements")
            return
        }
        do {
            let basePCM = try WhisperAudio.loadPCM(url: flacURL)

            // Battery: coarse (the OS reports level in ~1–5% steps) and
            // meaningless while charging — and reading this console output
            // usually means tethered to Xcode, i.e. charging. Captured anyway
            // per the T1.3 ask; interpret with the state + caveat below.
            let battery = await MainActor.run { () -> (level: Float, state: String) in
                UIDevice.current.isBatteryMonitoringEnabled = true
                return (UIDevice.current.batteryLevel, batteryStateString(UIDevice.current.batteryState))
            }
            // Decompose memory: MLX `activeMemory` is live arrays (model +
            // current activations); `cacheMemory` is MLX's reusable buffer pool
            // (freed buffers it holds for reuse — "grows significantly during
            // inference," per MLX's own docs). The OS `phys_footprint` ≈ active
            // + cache + non-MLX app memory, and is what iOS jetsam counts. The
            // baseline is captured *after* the earlier smoke sections, so its
            // cache is already warm — the point of showing the split.
            let baseSnap = MLX.Memory.snapshot()
            print("  MLX active / cache base    = \(formatBytes(baseSnap.activeMemory)) / \(formatBytes(baseSnap.cacheMemory))")
            print("  process footprint baseline = \(formatBytes(residentFootprintBytes()))")
            print("  battery start              = \(batteryString(battery.level)) (state: \(battery.state))")

            let wallStart = Date()
            // One transcriber across both lengths, matching the recorder (which
            // holds a single cached-model instance). The 60 s pass therefore
            // also pays the cold model load + Metal shader JIT.
            let transcriber = WhisperMLXTranscriber(fallbackLocation: location)
            for seconds in [60, 300] {
                try await measureDecode(seconds: seconds, basePCM: basePCM, transcriber: transcriber)
            }
            let wallElapsed = Int(Date().timeIntervalSince(wallStart))

            let endLevel = await MainActor.run { UIDevice.current.batteryLevel }
            print("  battery end                = \(batteryString(endLevel))")
            print("  battery delta              = \(batteryDeltaString(from: battery.level, to: endLevel)) over ~\(wallElapsed)s wall")
            print("  NOTE: battery delta is unreliable while charging — unplug + read via Console.app for a real number")
        } catch {
            print("  ERROR: \(error)")
        }
    }

    /// Tiles `basePCM` to `seconds`, writes a temp WAV, decodes it through the
    /// real file-based path, and reports decode time, realtime factor, and the
    /// peak resident footprint sampled during the decode.
    private static func measureDecode(
        seconds: Int,
        basePCM: [Float],
        transcriber: WhisperMLXTranscriber
    ) async throws {
        let target = seconds * WhisperAudio.sampleRate
        var pcm: [Float] = []
        pcm.reserveCapacity(target)
        while pcm.count < target { pcm.append(contentsOf: basePCM) }
        pcm = Array(pcm.prefix(target))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlxsmoke-\(seconds)s.wav")
        try? FileManager.default.removeItem(at: url)
        try writeWAV(pcm: pcm, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // Poll the process footprint while the decode runs (off the actor, so
        // it samples freely during the GPU-bound transcribe) and keep the max.
        let sampler = PeakMemorySampler()
        let poll = Task {
            while !Task.isCancelled {
                await sampler.record(residentFootprintBytes())
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        // Reset MLX's peak-active high-water so `peakMemory` below is attributable
        // to *this* decode, not the program-lifetime max.
        MLX.GPU.resetPeakMemory()
        let start = Date()
        let transcript = try await transcriber.transcribe(url, options: .whisperMLX)
        let decodeMs = Int(Date().timeIntervalSince(start) * 1000)
        poll.cancel()
        let peak = await sampler.peak
        let snap = MLX.Memory.snapshot()

        let realtime = Double(seconds) / (Double(decodeMs) / 1000.0)
        print("  ── \(seconds)s note ──")
        print("    decode time              = \(decodeMs) ms (\(String(format: "%.1f", realtime))× realtime)")
        print("    MLX active / cache       = \(formatBytes(snap.activeMemory)) / \(formatBytes(snap.cacheMemory))")
        print("    MLX peak active          = \(formatBytes(snap.peakMemory))")
        print("    peak process footprint   = \(formatBytes(peak))")
        print("    transcript chars         = \(transcript.count)")
    }

    /// Tracks the max `phys_footprint` observed across `record` calls. An actor
    /// so the polling task and the final read don't race the running decode.
    private actor PeakMemorySampler {
        private(set) var peak: UInt64 = 0
        func record(_ value: UInt64?) {
            if let value, value > peak { peak = value }
        }
    }

    /// Current process physical memory footprint (the figure Xcode's memory
    /// gauge shows), via `task_info(TASK_VM_INFO)`. `nil` if the call fails.
    private static func residentFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : nil
    }

    private static func formatBytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return "unavailable" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    /// `Int` overload for MLX's memory counters (which report signed byte counts).
    private static func formatBytes(_ bytes: Int) -> String {
        formatBytes(UInt64(max(0, bytes)))
    }

    private static func batteryString(_ level: Float) -> String {
        level < 0 ? "unavailable" : String(format: "%.0f%%", level * 100)
    }

    private static func batteryDeltaString(from start: Float, to end: Float) -> String {
        guard start >= 0, end >= 0 else { return "unavailable" }
        return String(format: "%.1f%%", (start - end) * 100)
    }

    private static func batteryStateString(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .charging: "charging"
        case .full: "full"
        case .unplugged: "unplugged"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
    }

    /// Writes mono 16 kHz Float32 PCM to a WAV at `url`. The writer is scoped so
    /// `AVAudioFile` finalizes the header before any reader opens the URL — a
    /// reader racing a live writer sees length 0 (bit us on device 2026-06-11,
    /// `loadPCM` hit "buffer.frameCapacity != 0").
    private static func writeWAV(pcm: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WhisperAudio.sampleRate),
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(pcm.count)
        ) else {
            throw WhisperAudio.Error.audioBufferAllocationFailed
        }
        buffer.frameLength = AVAudioFrameCount(pcm.count)
        pcm.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: pcm.count)
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
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
    private static func runWhisperTranscribe(_ location: ModelLocation?) async {
        print("[MLXSmoke] WhisperMLXTranscriber:")
        guard let location else {
            print("  model not downloaded — download it from Settings, then re-run. Skipping.")
            return
        }
        guard let flacURL = Bundle.main.url(forResource: "ls_test", withExtension: "flac") else {
            print("  ls_test.flac NOT FOUND — skipping transcribe")
            return
        }
        let transcriber = WhisperMLXTranscriber(fallbackLocation: location)
        let options = TranscriptionOptions.whisperMLX
        do {
            let coldStart = Date()
            let transcript = try await transcriber.transcribe(flacURL, options: options)
            let coldMs = Int(Date().timeIntervalSince(coldStart) * 1000)
            print("  transcribe time (cold)     = \(coldMs) ms")
            print("  transcript                 = '\(transcript)'")
            let passed = transcript.lowercased().contains(expectedSubstring)
            print("  substring check            = \(passed ? "PASS" : "FAIL") (expected '…\(expectedSubstring)…')")

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
