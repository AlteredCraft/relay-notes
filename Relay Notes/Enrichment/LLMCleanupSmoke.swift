#if DEBUG
import Foundation
import MLX
import OSLog

/// On-device smoke for the L2 cleanup model, mirroring `MLXSmoke` / `ParakeetSmoke`.
/// Invoked from the Settings debug section. The simulator can't run MLX, so this
/// only does useful work on the iPhone 15 Pro Max.
///
/// **Output goes through `os.Logger` (`.notice`, `.public`), not `print`** — so it
/// survives a crash and is readable in Console.app untethered (subsystem
/// `alteredcraft.Relay-Notes`, category `LLMCleanupSmoke`). The raw text + metrics
/// are logged *before* the generate call so an OOM mid-generation still leaves a trail.
///
/// **L2.0 — first section.** Loads the primary candidate (Gemma 4 E2B), cleans one
/// inline sample transcript via `MLXLanguageModel.clean`, and logs the RAW→CLEAN
/// pair plus load time, generation time, an (approximate) tok/s, and the **peak
/// `phys_footprint`** — the number that decides whether the `increased-memory-limit`
/// entitlement is load-bearing (§3.3). L2.2 swaps the inline sample for
/// `cleanup_fixtures.json`; L2.3 adds the candidate sweep + precise tok/s.
nonisolated enum LLMCleanupSmoke {

    private static let log = Logger(subsystem: "alteredcraft.Relay-Notes", category: "LLMCleanupSmoke")

    /// L2.0 primary (plan.L2.md §4) — the **non-QAT** 4-bit build, deliberately.
    /// The `-qat-4bit` build the plan first preferred OMITS `k_proj`/`v_proj` on
    /// Gemma 4's KV-sharing layers (15–34), but MLXLLM 3.31.3's `Gemma4Attention`
    /// declares a `kProj` Linear for *every* layer → keyNotFound at load
    /// (device-confirmed 2026-06-14). This build (the library's registered
    /// `LLMRegistry.gemma4_e2b_it_4bit` preset) materializes `k_proj` on all 35
    /// layers, so it loads. Still a multimodal config (`model_type: gemma4`);
    /// `Gemma4Model` runs the text tower. Fallback if this also fails:
    /// `mlx-community/Qwen3.5-4B-4bit` (pure-text, standard arch).
    private static let primaryRepo = "mlx-community/gemma-4-e2b-it-4bit"
    private static let primaryDesc = "Gemma 4 E2B (MLX 4-bit)"

    /// One inline sample for L2.0 (filler, false start, run-on, a likely
    /// misrecognition). L2.2 replaces this with the bundled fixture set.
    private static let sample = """
        so um i was thinking that we should uh maybe move the the standup to like \
        ten thirty instead of nine because half the team is is on the west coast \
        and they keep joining late and also we should probably talk about the the \
        new on boarding flow i think theres a bug where the the email never sends
        """

    private static func say(_ message: String) {
        log.notice("\(message, privacy: .public)")
    }

    static func run() async {
        say("=== L2.0 cleanup smoke START — \(primaryDesc) (\(primaryRepo)) ===")

        let model = MLXLanguageModel(source: .repoId(primaryRepo), modelDescription: primaryDesc)

        // 1. Load (downloads on first run). Log coarse progress every ~5%.
        say("loading model (first run downloads from Hugging Face — keep the app foregrounded)…")
        MLX.GPU.resetPeakMemory()
        let loadStart = Date()
        do {
            let lastPct = Atomic(-5)
            try await model.loadContainerIfNeeded { fraction in
                let pct = Int(fraction * 100)
                if pct >= lastPct.value + 5 {
                    lastPct.value = pct
                    say("  downloading… \(pct)%")
                }
            }
        } catch {
            say("load FAILED: \(error)")
            say("  (if this is an arch/load error, try the Qwen3.5-4B-4bit fallback — §4.)")
            return
        }
        let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)
        say("loaded in \(loadMs) ms — resident floor \(formatBytes(residentFootprintBytes()))")

        // 2. Clean one sample, sampling peak footprint across generation.
        say("RAW:   \(sample)")
        let sampler = PeakMemorySampler()
        let poll = Task {
            while !Task.isCancelled {
                await sampler.record(residentFootprintBytes())
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        MLX.GPU.resetPeakMemory()
        let t0 = Date()
        let cleaned: String
        do {
            cleaned = try await model.clean(sample)
        } catch {
            poll.cancel()
            say("clean FAILED: \(error)")
            return
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        poll.cancel()
        let peak = await sampler.peak
        let snap = MLX.Memory.snapshot()

        say("CLEAN: \(cleaned)")

        // Approximate tok/s from whitespace word count (≈0.75 word/token). Precise
        // tok/s via streamed token counts is an L2.3 refinement.
        let words = cleaned.split { $0.isWhitespace }.count
        let approxToks = Int(Double(words) / 0.75)
        let toksPerSec = ms > 0 ? Double(approxToks) / (Double(ms) / 1000) : 0
        say("── metrics ──")
        say("  generation time   = \(ms) ms")
        say("  output            = \(words) words (~\(approxToks) tok, approx)")
        say("  throughput        ≈ \(String(format: "%.1f", toksPerSec)) tok/s (approx; precise at L2.3)")
        say("  MLX active / cache = \(formatBytes(snap.activeMemory)) / \(formatBytes(snap.cacheMemory))")
        say("  MLX peak active    = \(formatBytes(snap.peakMemory))")
        say("  PEAK footprint     = \(formatBytes(peak))")

        // Entitlement verdict — peak vs the ~3 GB no-entitlement jetsam ceiling and
        // the ~5.73 GB device working-set budget (Appendix C).
        let noEntitlementCeiling: UInt64 = 3 * 1024 * 1024 * 1024
        let deviceBudget: UInt64 = UInt64(5.73 * 1024 * 1024 * 1024)
        if peak == 0 {
            say("  ENTITLEMENT verdict = unavailable (footprint read failed)")
        } else if peak < noEntitlementCeiling {
            say("  ENTITLEMENT verdict = FITS without increased-memory-limit (peak < ~3 GB)")
        } else if peak < deviceBudget {
            say("  ENTITLEMENT verdict = NEEDS increased-memory-limit (peak \(formatBytes(peak)) in 3–5.73 GB band)")
        } else {
            say("  ENTITLEMENT verdict = OVER BUDGET — peak \(formatBytes(peak)) > ~5.73 GB device working set")
        }

        await model.evict()
        say("=== L2.0 cleanup smoke END ===")
    }

    // MARK: - Helpers (lifted from ParakeetSmoke; unify into a shared DEBUG util if a fourth consumer appears)

    /// Tracks the max `phys_footprint` across `record` calls during generation — an
    /// actor so the polling task and the final read don't race.
    private actor PeakMemorySampler {
        private(set) var peak: UInt64 = 0
        func record(_ value: UInt64?) {
            if let value, value > peak { peak = value }
        }
    }

    /// Tiny mutable box for the @Sendable progress closure to update its last-logged
    /// percent without capturing `var` state.
    private final class Atomic<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T
        init(_ value: T) { _value = value }
        var value: T {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
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

    /// `MLX.Memory.snapshot()` fields are `Int` — overload so the active/cache/peak
    /// lines format without a cast.
    static func formatBytes(_ bytes: Int) -> String {
        formatBytes(UInt64(max(0, bytes)))
    }
}
#endif
