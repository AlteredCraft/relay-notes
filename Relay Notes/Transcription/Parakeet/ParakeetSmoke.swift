#if DEBUG
import Foundation
import MLX
import OSLog
import Synchronization

/// On-device smoke for the Parakeet (TDT 0.6b v2) port as it lands, mirroring
/// `MLXSmoke` for Whisper. Invoked from the Tuning sheet's debug section. The
/// simulator crashes on any MLX op, so this only does useful work on the
/// iPhone 15 Pro Max.
///
/// **Output goes through `os.Logger` (`.notice`), not `print`** — so it survives
/// a crash and is readable in Console.app untethered (filter subsystem
/// `alteredcraft.Relay-Notes`, category `ParakeetSmoke`). `print` is ephemeral to
/// the Xcode debug session and was lost when the first run OOM'd.
///
/// **T2.1a — the first section.** Brings the 2.47 GB safetensors onto the device
/// (a throwaway `URLSession` fetch — the real downloadable-model store is T2.2),
/// confirms `ParakeetConfig` decodes the real `config.json`, dumps the collapsed
/// key namespace + dtype (pure metadata — logged *before* any materialization so
/// it survives even if the cast OOMs), then casts F32→bf16 **incrementally with
/// the buffer cache capped** to measure the resident *floor* without holding the
/// full F32 set and the bf16 copy at once. The floor is just the bf16 weights;
/// the memory go/no-go is the *peak* during a forward pass (T2.1c).
///
/// **Device-validated 2026-06-13 (iPhone 15 Pro Max): floor ~1.2 GB** (617.87M
/// params; F32 2.47 GB on disk → bf16). The incremental cast-and-release here is
/// not just a measurement trick — it is the **load strategy the real
/// `ParakeetMLXTranscriber` must use.** The reference's `loadParakeetModel`
/// (load F32 into the module, then cast *all* params and `update`) holds F32 and
/// bf16 at once (~3.7 GB) and OOMs the 8 GB device at the ~3 GB no-entitlement
/// ceiling — observed here as a jetsam kill at ~3.1 GB before the fix.
nonisolated enum ParakeetSmoke {

    // MARK: - Source (pinned to a public mlx-community repo; DEBUG dev fetch only)

    static let weightsURL = URL(string:
        "https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v2/resolve/main/model.safetensors")!
    static let configURL = URL(string:
        "https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v2/resolve/main/config.json")!

    private static let log = Logger(subsystem: "alteredcraft.Relay-Notes", category: "ParakeetSmoke")

    /// The bundled `ls_test.flac` is a fixed LibriSpeech clip, so its decode is
    /// deterministic — asserting this stable substring (case-insensitive) turns
    /// the T2.1d end-to-end decode into a pass/fail gate (same fixture + phrase as
    /// the Whisper `MLXSmoke`). This is the test that confirms the whole port.
    private static let expectedSubstring = "openly shouldered the burden"

    /// `.notice` is persisted (survives a crash) and marked `.public` so the
    /// diagnostic text isn't redacted to `<private>` in Console.app.
    private static func say(_ message: String) {
        log.notice("\(message, privacy: .public)")
    }

    static func run() async {
        // Cheap → end-to-end. T2.1b (featurizer) needs no weights and logs in
        // seconds; T2.1d (`runDecode`) loads the **full** model (encoder + decoder
        // + joint), transcribes `ls_test.flac`, asserts the substring gate, and
        // reports the full-model peak footprint — subsuming the T2.1c encoder load.
        // T2.1a (`runLoadFootprint`) and T2.1c (`runEncoder`, encoder-only peak)
        // are device-validated and recorded — call them manually if re-measuring.
        await runFeaturizer()
        await runDecode()
    }

    // MARK: - T2.1b — mel front-end (no weights; mirrors MLXSmoke.runWhisperAudio)

    /// Computes the Parakeet log-mel on the bundled `ls_test.flac` and logs its
    /// shape + value range. Weight-independent, so it's the fast inner loop while
    /// tuning the §5.2 featurizer risks. Numerical correctness is only *confirmed*
    /// at the T2.1d end-to-end substring gate; here we just check the pipeline
    /// runs and produces a `[1, ~671, 128]` tensor with a sane range.
    static func runFeaturizer() async {
        say("=== T2.1b mel front-end START ===")

        // Only `config.json` is needed (the preprocessor block). Weights are
        // already on the device from T2.1a, so this returns without downloading.
        let dir: URL
        do {
            dir = try await ensureModelDownloaded()
        } catch {
            say("download failed: \(error) — skipping featurizer.")
            return
        }

        let config: ParakeetPreprocessConfig
        do {
            config = try ParakeetTDTConfig.load(from: dir.appendingPathComponent("config.json")).preprocessor
        } catch {
            say("config decode FAILED: \(error) — skipping featurizer.")
            return
        }
        say("preprocessor = \(config.features) mels, n_fft \(config.nFFT), win \(config.winLength), hop \(config.hopLength), normalize \(config.normalize), preemph \(config.preemph.map { "\($0)" } ?? "off")")

        guard let flacURL = Bundle.main.url(forResource: "ls_test", withExtension: "flac") else {
            say("ls_test.flac NOT FOUND in bundle — skipping featurizer.")
            return
        }

        do {
            let pcm = try WhisperAudio.loadPCM(url: flacURL)
            say("ls_test.flac PCM samples = \(pcm.count) (≈\(pcm.count / config.sampleRate)s @ \(config.sampleRate) Hz)")

            let filters = ParakeetAudio.melFilterbank(config: config)
            eval(filters)  // `eval` is MLX.eval(_:) — forces the lazy graph, not code exec.
            say("mel filterbank shape     = \(filters.shape) (Slaney; expect [\(config.features), \(config.nFFT / 2 + 1)])")

            let audio = MLXArray(pcm)
            let mel = ParakeetAudio.logMel(audio, config: config, filters: filters)
            eval(mel)
            let melMin: Float = mel.min().item()
            let melMax: Float = mel.max().item()
            let melMean: Float = mel.mean().item()
            say("log-mel shape            = \(mel.shape) (expect [1, 667, \(config.features)] for ls_test; = 1 + samples/hop)")
            say("log-mel range / mean     = [\(melMin), \(melMax)] / \(melMean)")
        } catch {
            say("featurizer ERROR: \(error)")
        }
        say("=== T2.1b END ===")
    }

    // MARK: - T2.1c — FastConformer encoder (load + forward + peak footprint)

    /// Loads the encoder (incremental bf16 cast-release), featurizes
    /// `ls_test.flac`, runs the forward pass, and logs output shape + timing +
    /// the **peak `phys_footprint`** sampled across the forward — the number that
    /// decides whether the `increased-memory-limit` entitlement is needed (§3.1).
    /// `Memory.cacheLimit = 0` (set by the loader) bounds the buffer pool, so the
    /// peak reported is close to the true live working set, not the reclaimable
    /// cache high-water.
    static func runEncoder() async {
        say("=== T2.1c FastConformer encoder START ===")

        let dir: URL
        do {
            dir = try await ensureModelDownloaded()
        } catch {
            say("download failed: \(error) — skipping encoder.")
            return
        }

        let config: ParakeetTDTConfig
        do {
            config = try ParakeetTDTConfig.load(from: dir.appendingPathComponent("config.json"))
        } catch {
            say("config decode FAILED: \(error) — skipping encoder.")
            return
        }

        guard let flacURL = Bundle.main.url(forResource: "ls_test", withExtension: "flac") else {
            say("ls_test.flac NOT FOUND in bundle — skipping encoder.")
            return
        }

        do {
            // Featurize in float32 (precision-sensitive per-feature norm), then
            // cast the mel to bf16 to match the encoder's resident dtype.
            let pcm = try WhisperAudio.loadPCM(url: flacURL)
            let filters = ParakeetAudio.melFilterbank(config: config.preprocessor)
            let mel = ParakeetAudio
                .logMel(MLXArray(pcm), config: config.preprocessor, filters: filters)
                .asType(.bfloat16)
            eval(mel)  // `eval` is MLX.eval(_:) — forces the lazy graph, not code exec.
            say("mel input shape          = \(mel.shape) (bf16)")

            // Load encoder weights via the incremental cast-release path (§3.1).
            say("loading encoder weights (incremental bf16 cast-release)…")
            MLX.GPU.resetPeakMemory()
            let loadStart = Date()
            let encoder = try ParakeetConformerEncoder.load(
                weightsURL: dir.appendingPathComponent("model.safetensors"), config: config)
            let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)
            let loadSnap = MLX.Memory.snapshot()
            say("encoder loaded in \(loadMs) ms")
            say("  resident floor         = \(formatBytes(residentFootprintBytes())) (encoder bf16 weights)")
            say("  MLX active / cache     = \(formatBytes(loadSnap.activeMemory)) / \(formatBytes(loadSnap.cacheMemory))")

            // Forward pass, sampling phys_footprint off-actor so it captures the
            // GPU-bound peak. resetPeakMemory so MLX peak-active is attributable here.
            let sampler = PeakMemorySampler()
            let poll = Task {
                while !Task.isCancelled {
                    await sampler.record(residentFootprintBytes())
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
            MLX.GPU.resetPeakMemory()
            let fwdStart = Date()
            let out = encoder(mel)
            eval(out)
            let fwdMs = Int(Date().timeIntervalSince(fwdStart) * 1000)
            poll.cancel()
            let peak = await sampler.peak
            let snap = MLX.Memory.snapshot()

            let outMin: Float = out.min().item()
            let outMax: Float = out.max().item()
            let outMean: Float = out.mean().item()
            say("encoder output shape     = \(out.shape) (expect [1, ~84, \(config.encoder.dModel)] for ls_test)")
            say("encoder output range/mean= [\(outMin), \(outMax)] / \(outMean)")
            say("forward pass time        = \(fwdMs) ms")
            say("── memory (forward pass) ──")
            say("  MLX active / cache     = \(formatBytes(snap.activeMemory)) / \(formatBytes(snap.cacheMemory))")
            say("  MLX peak active        = \(formatBytes(snap.peakMemory))")
            say("  PEAK process footprint = \(formatBytes(peak))")
            let ceiling: UInt64 = 3 * 1024 * 1024 * 1024  // ~3 GB no-entitlement jetsam ceiling
            let verdict =
                peak == 0
                ? "unavailable"
                : (peak < ceiling ? "FITS without increased-memory-limit" : "NEEDS increased-memory-limit")
            say("ENTITLEMENT: peak vs ~3 GB no-entitlement ceiling → \(verdict)")
        } catch {
            say("encoder ERROR: \(error)")
        }
        say("=== T2.1c END ===")
    }

    // MARK: - T2.1d — TDT decode (end-to-end substring gate)

    /// The correctness gate. Loads the **full** model (encoder + decoder + joint),
    /// featurizes `ls_test.flac`, runs encoder → TDT greedy decode → vocab decode,
    /// and asserts the transcript contains the expected substring. This is what
    /// confirms the whole port (and arbitrates the §5.2 featurizer risks). Also
    /// reports the full-model peak footprint (the real end-state entitlement
    /// number, ≥ the T2.1c encoder-only figure by the tiny decoder/joint).
    static func runDecode() async {
        say("=== T2.1d TDT decode (end-to-end substring gate) START ===")

        let dir: URL
        do {
            dir = try await ensureModelDownloaded()
        } catch {
            say("download failed: \(error) — skipping decode.")
            return
        }

        let config: ParakeetTDTConfig
        do {
            config = try ParakeetTDTConfig.load(from: dir.appendingPathComponent("config.json"))
        } catch {
            say("config decode FAILED: \(error) — skipping decode.")
            return
        }

        guard let flacURL = Bundle.main.url(forResource: "ls_test", withExtension: "flac") else {
            say("ls_test.flac NOT FOUND in bundle — skipping decode.")
            return
        }

        do {
            let pcm = try WhisperAudio.loadPCM(url: flacURL)
            let filters = ParakeetAudio.melFilterbank(config: config.preprocessor)
            let mel = ParakeetAudio
                .logMel(MLXArray(pcm), config: config.preprocessor, filters: filters)
                .asType(.bfloat16)
            eval(mel)  // `eval` is MLX.eval(_:) — forces the lazy graph, not code exec.

            say("loading full model (encoder+decoder+joint; incremental bf16 cast-release)…")
            let loadStart = Date()
            let model = try ParakeetTDTModel.load(
                weightsURL: dir.appendingPathComponent("model.safetensors"), config: config)
            let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)
            say("model loaded in \(loadMs) ms — resident floor \(formatBytes(residentFootprintBytes()))")

            // Transcribe (encode + greedy decode) with peak sampling.
            let sampler = PeakMemorySampler()
            let poll = Task {
                while !Task.isCancelled {
                    await sampler.record(residentFootprintBytes())
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
            // Diagnostic samples to cross-check against the Python oracle if the
            // gate fails. Reference (ls_test.flac, validated on Mac):
            //   mel[0,0,:5] ≈ [-0.690, -0.790, -0.812, -1.083, -1.061]
            //   enc range ≈ [-0.645, 0.535]; enc[0,0,:5] ≈ [0.028, -0.022, 0.058, 0.004, 0.021]
            say("mel[0,0,:5]              = \(firstValues(mel[0, 0], 5))")
            MLX.GPU.resetPeakMemory()
            let t0 = Date()
            let features = model.encoder(mel)
            eval(features)
            let encMin: Float = features.asType(.float32).min().item(Float.self)
            let encMax: Float = features.asType(.float32).max().item(Float.self)
            say("encoder out shape        = \(features.shape) range [\(encMin), \(encMax)]")
            say("enc[0,0,:5]              = \(firstValues(features[0, 0], 5))")
            let transcript = parakeetDecodeTokens(model.decodeGreedy(features), vocabulary: model.vocabulary)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            poll.cancel()
            let peak = await sampler.peak
            let snap = MLX.Memory.snapshot()

            say("transcript: \"\(transcript)\"")
            let pass = transcript.lowercased().contains(expectedSubstring)
            say("substring check (\"\(expectedSubstring)\") = \(pass ? "PASS ✅" : "FAIL ❌")")
            say("transcribe time          = \(ms) ms (encode + greedy decode)")
            say("── memory (full model) ──")
            say("  MLX active / cache     = \(formatBytes(snap.activeMemory)) / \(formatBytes(snap.cacheMemory))")
            say("  MLX peak active        = \(formatBytes(snap.peakMemory))")
            say("  PEAK process footprint = \(formatBytes(peak))")
            let ceiling: UInt64 = 3 * 1024 * 1024 * 1024
            let verdict =
                peak == 0
                ? "unavailable"
                : (peak < ceiling ? "FITS without increased-memory-limit" : "NEEDS increased-memory-limit")
            say("ENTITLEMENT (full model): peak vs ~3 GB ceiling → \(verdict)")
        } catch {
            say("decode ERROR: \(error)")
        }
        say("=== T2.1d END ===")
    }

    /// Tracks the max `phys_footprint` across `record` calls during the forward
    /// pass — an actor so the polling task and the final read don't race. Mirrors
    /// `MLXSmoke.PeakMemorySampler`.
    private actor PeakMemorySampler {
        private(set) var peak: UInt64 = 0
        func record(_ value: UInt64?) {
            if let value, value > peak { peak = value }
        }
    }

    // MARK: - T2.1a — load / footprint / key-dump

    static func runLoadFootprint() async {
        say("=== T2.1a load / footprint / key-dump START ===")
        let dir: URL
        do {
            dir = try await ensureModelDownloaded()
        } catch {
            say("download failed: \(error) — skipping.")
            return
        }

        let configURL = dir.appendingPathComponent("config.json")
        let weightsURL = dir.appendingPathComponent("model.safetensors")

        // 1. Config parse sanity — proves ParakeetConfig decodes the real file.
        do {
            let config = try ParakeetTDTConfig.load(from: configURL)
            say("config OK:")
            say("  encoder      = d_model \(config.encoder.dModel), \(config.encoder.nLayers) layers, \(config.encoder.nHeads) heads, subsample ×\(config.encoder.subsamplingFactor)")
            say("  preprocessor = \(config.preprocessor.features) mels, n_fft \(config.preprocessor.nFFT), normalize \(config.preprocessor.normalize), preemph \(config.preprocessor.preemph.map { "\($0)" } ?? "none")")
            say("  decoder/joint= pred_hidden \(config.decoder.prednet.predHidden) ×\(config.decoder.prednet.predRNNLayers), joint_hidden \(config.joint.jointnet.jointHidden), vocab \(config.joint.vocabulary.count)")
            say("  decoding     = \(config.decoding.modelType), durations \(config.decoding.durations), max_symbols \(config.decoding.maxSymbols)")
        } catch {
            say("config decode FAILED: \(error)")
            return
        }

        // 2. Raw weight load — lazy (mlx_load_safetensors), so footprint stays at
        // the file-handle floor until something forces materialization.
        let fileBytes = (try? FileManager.default.attributesOfItem(atPath: weightsURL.path)[.size] as? Int64) ?? nil
        say("safetensors on disk   = \(formatBytes(fileBytes.map(UInt64.init)))")
        say("footprint before load = \(formatBytes(residentFootprintBytes()))")

        var arrays: [String: MLXArray]
        do {
            arrays = try MLX.loadArrays(url: weightsURL)
        } catch {
            say("loadArrays FAILED: \(error)")
            return
        }
        say("footprint after load  = \(formatBytes(residentFootprintBytes())) (low ⇒ lazy/mmap; high ⇒ full read)")

        let totalParams = arrays.values.reduce(0) { $0 + $1.shape.reduce(1, *) }
        say("tensors               = \(arrays.count)")
        say("total parameters      ≈ \(totalParams) (\(String(format: "%.2f", Double(totalParams) / 1_000_000))M)")

        // dtype histogram (string-keyed — no DType case assumptions). Metadata
        // only; does not materialize.
        var dtypes: [String: Int] = [:]
        for v in arrays.values { dtypes["\(v.dtype)", default: 0] += 1 }
        say("dtype histogram       = \(dtypes.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))")

        // 3. Collapsed key-namespace dump — numeric path components → {N}, tallied.
        // The input for the safetensors→module key remap (T2.1c/d). Logged here,
        // BEFORE the risky cast, so it survives even if the cast OOMs.
        var templates: [String: Int] = [:]
        for k in arrays.keys { templates[keyTemplate(k), default: 0] += 1 }
        say("key templates (\(templates.count) distinct):")
        for (t, c) in templates.sorted(by: { $0.key < $1.key }) {
            say("  \(String(format: "%3d", c))×  \(t)")
        }

        // 4. bf16 cast — incremental + cache-capped to bound peak.
        // `cacheLimit: 0` stops MLX's reuse pool from hoarding the freed F32
        // buffers; removing each entry from `arrays` drops its F32 reference once
        // the bf16 is materialized, so we never hold the full F32 set (~2.5 GB)
        // and the bf16 copy (~1.2 GB) at once (that combination OOM'd the first
        // run). Footprint logged every 100 tensors so the last durable line
        // localizes a crash. (`eval` is `MLX.eval(_:)` — materializes the lazy
        // graph, not code execution.)
        say("--- bf16 cast (cacheLimit=0, incremental release) ---")
        MLX.GPU.set(cacheLimit: 0)
        MLX.GPU.resetPeakMemory()
        var bf16: [String: MLXArray] = [:]
        bf16.reserveCapacity(arrays.count)
        let keys = arrays.keys.sorted()
        let total = keys.count
        var done = 0
        for k in keys {
            // Remove from `arrays` ITSELF (not a copy) so the F32 array's last
            // reference drops once its bf16 is materialized, and cacheLimit:0
            // returns the buffer to the OS. The earlier `var remaining = arrays`
            // copy left `arrays` pinning all 697 F32 buffers → they accumulated
            // to ~2.1 GB alongside the bf16 and OOM'd at ~3.1 GB.
            guard let v = arrays.removeValue(forKey: k) else { continue }
            let b = v.asType(.bfloat16)
            eval(b)
            bf16[k] = b
            done += 1
            if done % 100 == 0 {
                say("  cast \(done)/\(total) — footprint \(formatBytes(residentFootprintBytes()))")
            }
        }
        say("cast complete (\(done) tensors).")

        let snap = MLX.Memory.snapshot()
        say("── after bf16 cast ──")
        say("  MLX active / cache  = \(formatBytes(snap.activeMemory)) / \(formatBytes(snap.cacheMemory))")
        say("  MLX peak active     = \(formatBytes(snap.peakMemory))")
        say("  process footprint   = \(formatBytes(residentFootprintBytes()))")
        say("NOTE: resident FLOOR (bf16 weights). Memory go/no-go is the PEAK during a")
        say("      forward pass — measured once the encoder runs (T2.1c).")
        say("=== T2.1a END ===")
    }

    // MARK: - Download bridge (DEBUG-only; replaced by DownloadableModelStore in T2.2)

    /// Idempotently fetches `config.json` + `model.safetensors` into
    /// `Application Support/parakeet/tdt-0.6b-v2/`. No SHA pin — that's T2.2's
    /// job; this just gets bytes on the device for the smoke.
    static func ensureModelDownloaded() async throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("parakeet/tdt-0.6b-v2", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let configDest = dir.appendingPathComponent("config.json")
        if !fm.fileExists(atPath: configDest.path) {
            say("downloading config.json…")
            let (tmp, _) = try await URLSession.shared.download(from: configURL)
            try? fm.removeItem(at: configDest)
            try fm.moveItem(at: tmp, to: configDest)
        }

        let weightsDest = dir.appendingPathComponent("model.safetensors")
        if !fm.fileExists(atPath: weightsDest.path) {
            say("downloading model.safetensors (~2.5 GB, one-time, several minutes)…")
            // Reuse the Whisper download machinery (widened timeouts +
            // waitsForConnectivity + progress) rather than a bare
            // URLSession.shared.download — the latter aborted on a transient
            // HF-Xet CDN stall (60 s request timeout). Keep the device awake and
            // the app foregrounded for the duration.
            let coordinator = DownloadCoordinator()
            let lastPct = Mutex(-5)
            let tmp = try await coordinator.download(from: weightsURL) { frac in
                let pct = Int(frac * 100)
                let emit = lastPct.withLock { last -> Bool in
                    if pct >= last + 5 { last = pct; return true }
                    return false
                }
                if emit { say("  downloading… \(pct)%") }
            }
            try? fm.removeItem(at: weightsDest)
            try fm.moveItem(at: tmp, to: weightsDest)
            var u = weightsDest
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? u.setResourceValues(values)
            say("download complete.")
        } else {
            say("model already present at \(dir.path)")
        }
        return dir
    }

    // MARK: - Helpers

    /// Collapse numeric path components so 24 conformer layers fold into one
    /// template: `encoder.layers.3.self_attn.linear_q.weight` → `encoder.layers.{N}.self_attn.linear_q.weight`.
    static func keyTemplate(_ key: String) -> String {
        key.split(separator: ".", omittingEmptySubsequences: false)
            .map { Int($0) != nil ? "{N}" : String($0) }
            .joined(separator: ".")
    }

    // Mirrors the footprint helpers in MLXSmoke; kept local to avoid touching the
    // working Whisper smoke. Unify into a shared DEBUG util if a third consumer appears.

    /// First `n` scalar values of a 1-D `MLXArray`, formatted for log comparison
    /// against the Python oracle. Casts to f32 so bf16 arrays read out cleanly.
    static func firstValues(_ a: MLXArray, _ n: Int) -> String {
        let f = a.asType(.float32)
        let count = min(n, a.shape.last ?? 0)
        let vals = (0 ..< count).map { String(format: "%.4f", f[$0].item(Float.self)) }
        return "[" + vals.joined(separator: ", ") + "]"
    }

    static func residentFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : nil
    }

    static func formatBytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return "unavailable" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    static func formatBytes(_ bytes: Int) -> String {
        formatBytes(UInt64(max(0, bytes)))
    }
}
#endif
