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

    /// `.notice` is persisted (survives a crash) and marked `.public` so the
    /// diagnostic text isn't redacted to `<private>` in Console.app.
    private static func say(_ message: String) {
        log.notice("\(message, privacy: .public)")
    }

    static func run() async {
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
