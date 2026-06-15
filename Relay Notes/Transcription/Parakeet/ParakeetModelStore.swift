import Foundation

/// The on-device Parakeet model bundle — `DownloadableModelStore` bound to
/// `ModelDownloadSpec.parakeetTDT06bV2` (T2.2). Both the 2.47 GB F32
/// `model.safetensors` **and** `config.json` are downloaded + SHA-256-verified
/// into `Application Support/parakeet/tdt-0.6b-v2/` (nothing is bundled — unlike
/// Whisper, Parakeet's config isn't a hand-staged asset).
///
/// Thin subclass (no stored properties) so the no-arg `ParakeetModelStore()` is
/// available to the smoke and the future Parakeet Settings wiring (T2.5).
@MainActor
final class ParakeetModelStore: DownloadableModelStore {

    init(fileManager: FileManager = .default) {
        super.init(spec: .parakeetTDT06bV2, fileManager: fileManager)
    }

    /// Convenience for tests — explicit directory.
    init(modelDirectory: URL, fileManager: FileManager = .default) {
        super.init(spec: .parakeetTDT06bV2, modelDirectory: modelDirectory, fileManager: fileManager)
    }
}
