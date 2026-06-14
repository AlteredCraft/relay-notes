import Foundation

/// The on-device Whisper model bundle — `DownloadableModelStore` bound to
/// `ModelDownloadSpec.whisperSmallEn` (T2.2 generalized the machinery; the spec,
/// download/verify/install logic, and `DownloadCoordinator` live in
/// `DownloadableModelStore.swift`).
///
/// Files live in `Application Support/whisper/small.en/`:
///   - `weights.safetensors` — **downloaded** from HuggingFace (~481 MB FP16).
///   - `config.json` / `gpt2.tiktoken` / `mel_filters.safetensors` — **staged
///     from the app bundle** (small, version-locked with the Swift port).
///
/// A thin subclass (no stored properties, so observation is unaffected) keeps the
/// no-arg `WhisperModelStore()` call sites and the back-compat static accessors
/// the smoke / tests read.
@MainActor
final class WhisperModelStore: DownloadableModelStore {

    init(fileManager: FileManager = .default) {
        super.init(spec: .whisperSmallEn, fileManager: fileManager)
    }

    /// Convenience for tests — explicit directory.
    init(modelDirectory: URL, fileManager: FileManager = .default) {
        super.init(spec: .whisperSmallEn, modelDirectory: modelDirectory, fileManager: fileManager)
    }

    // Back-compat accessors (MLXSmoke / WhisperModelStoreTests) — forward to the
    // spec's single remote file so there's one source of truth.
    nonisolated static var downloadURL: URL { ModelDownloadSpec.whisperSmallEn.remoteFiles[0].url }
    nonisolated static var expectedSHA256: String { ModelDownloadSpec.whisperSmallEn.remoteFiles[0].sha256 }
    nonisolated static var expectedSize: Int64 { ModelDownloadSpec.whisperSmallEn.remoteFiles[0].size }
}
