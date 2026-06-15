import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// On-device cleanup model — the MLX conformer of the `LanguageModel` spine, the
/// LLM-enrichment analogue of `WhisperMLXTranscriber` / `ParakeetMLXTranscriber`
/// (L2.0, plan.L2.md §5.2). Loads a model **container** from an HF repo id via
/// `mlx-swift-lm`'s `LLMModelFactory` — using our hand-rolled `HuggingFaceBridge`
/// for the download + tokenizer (so we don't link `MLXHuggingFace`, which would be
/// the only thing to compile its swift-syntax macro plugin) — and generates
/// through the high-level `ChatSession`, which applies the model's chat template
/// via the tokenizer (we never hand-bake it).
///
/// **`actor`**, like the MLX transcribers and for the same reason: the loaded
/// `ModelContainer` is non-`Sendable` GPU-bound state cached across calls, and
/// actor isolation is what makes that safe behind the `Sendable`, `nonisolated`
/// `LanguageModel` protocol. Generation serializes through the actor — correct for
/// a single-model GPU engine. One model lives at a time; `evict()` drops it so the
/// L2.3 harness can sweep candidates without two LLMs co-resident (§3.3).
///
/// **Naming:** `MLXLMCommon` also exports a public `LanguageModel` (its core model
/// protocol), so the conformance is qualified `Relay_Notes.LanguageModel` — this is
/// the one file that imports both, exactly as anticipated in `LanguageModel.swift`.
actor MLXLanguageModel: Relay_Notes.LanguageModel {
    /// Where to load the model from. The **app** loads from a `.directory` (a
    /// `CleanupModelStore`-downloaded snapshot — no Hub needed at load time); the
    /// **DEBUG smoke** loads by `.repoId` (downloads via the HF bridge — convenient
    /// for sweeping candidate models without pinning a spec).
    enum Source: Sendable {
        case repoId(String)
        case directory(URL)
    }

    /// Provenance for logs / persisted on the `Note` (e.g. "Gemma 4 E2B (MLX
    /// 4-bit)"). `nonisolated` so callers read it without awaiting the actor.
    nonisolated let modelDescription: String

    private let source: Source
    /// The loaded model, cached across calls. Single-entry by design (§3.3).
    private var container: ModelContainer?

    init(source: Source, modelDescription: String) {
        self.source = source
        self.modelDescription = modelDescription
    }

    /// Load (once) and cache the container. `.directory` loads from disk (the store
    /// already downloaded it — no progress); `.repoId` downloads via the HF bridge
    /// on first call, reporting `progress` (0…1). Later calls reuse the resident model.
    @discardableResult
    func loadContainerIfNeeded(
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ModelContainer {
        if let container { return container }
        let loaded: ModelContainer
        switch source {
        case .repoId(let id):
            loaded = try await LLMModelFactory.shared.loadContainer(
                from: HubDownloaderBridge(),
                using: HuggingFaceTokenizerLoader(),
                configuration: ModelConfiguration(id: id),
                progressHandler: { p in progress?(p.fractionCompleted) }
            )
        case .directory(let dir):
            loaded = try await LLMModelFactory.shared.loadContainer(
                from: dir,
                using: HuggingFaceTokenizerLoader()
            )
        }
        container = loaded
        return loaded
    }

    func clean(_ raw: String, personalization: CleanupPersonalization) async throws -> String {
        let container = try await loadContainerIfNeeded()
        // Deterministic decode — cleanup must not invent (temperature 0 ⇒ greedy).
        var parameters = GenerateParameters()
        parameters.temperature = 0
        // Bound the decode so a degenerate repetition loop can't run unbounded:
        // cleanup output is ~input-sized, so a generous multiple of the input's
        // token estimate is far above any legitimate result yet still self-
        // terminates a runaway (GH #12). Without this, only an EOS token stops it.
        parameters.maxTokens = CleanupTokenBudget.maxTokens(forRawCharacterCount: raw.count)
        // Instructions are rebuilt per call, so an edited personalization takes
        // effect on the next cleanup without reloading the (cached) container.
        let session = ChatSession(
            container,
            instructions: CleanupPrompt.system(personalization: personalization),
            generateParameters: parameters)
        // The raw transcript is the user turn; the tokenizer wraps it in the chat
        // template. `respond` collects the full streamed string.
        let output = try await session.respond(to: raw)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drop the loaded model + clear the MLX buffer pool so the next model isn't
    /// co-resident with this one (§3.3 — the single-live-MLX-engine rule, mirroring
    /// `TranscriberFactory`'s eviction for the ASR engines).
    func evict() {
        container = nil
        MLX.GPU.clearCache()
    }
}
