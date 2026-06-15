import Foundation

/// The on-device cleanup model bundle — `DownloadableModelStore` bound to
/// `ModelDownloadSpec.gemmaCleanupE2B` (L2). The complete Gemma 4 E2B HF snapshot
/// (weights + config + tokenizer + chat template) is downloaded + SHA-256-verified
/// into `Application Support/llm/gemma-4-e2b-it-4bit/`, then loaded by
/// `mlx-swift-lm` via `loadContainer(directory:using:)` — the same store machinery
/// the transcribers use (Whisper/Parakeet), so cleanup-model management lives in
/// the Tuning sheet exactly like theirs.
///
/// Thin subclass (no stored properties) so the no-arg `CleanupModelStore()` is
/// available to `ModelStores` and the unit tests.
@MainActor
final class CleanupModelStore: DownloadableModelStore {

    init(fileManager: FileManager = .default) {
        super.init(spec: .gemmaCleanupE2B, fileManager: fileManager)
    }

    /// Convenience for tests — explicit directory.
    init(modelDirectory: URL, fileManager: FileManager = .default) {
        super.init(spec: .gemmaCleanupE2B, modelDirectory: modelDirectory, fileManager: fileManager)
    }
}
