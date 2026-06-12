import Foundation

/// Where the Whisper assets (config + tokenizer + mel filters + weights) live
/// at load time.
///
/// - `.bundled` — flat at the `.app` root, found via
///   `Bundle.main.url(forResource:withExtension:)` (intentionally ignores any
///   subdirectory layout — Xcode's file-system-synchronized group flattens
///   resources at build time; see CLAUDE.md). **No longer carries the weights:**
///   the 481 MB `weights.safetensors` is excluded from the bundle (download-only
///   since 2026-06-11, via a `PBXFileSystemSynchronizedBuildFileExceptionSet`
///   entry), so `.bundled` resolves only the small staged assets (`config.json`,
///   `gpt2.tiktoken`, `mel_filters.safetensors`) and the `ls_test.flac` fixture.
///   A full `WhisperModel.load(from: .bundled)` now fails (no weights) — load
///   from a downloaded `.directory` instead.
/// - `.directory(URL)` — a real on-disk directory (the app uses
///   `Application Support/whisper/small.en/`, populated by `WhisperModelStore`'s
///   download + asset staging). File lookup is
///   `dir.appendingPathComponent("<name>.<ext>")`. The only location that can
///   load a complete model.
nonisolated enum WhisperModelLocation: Sendable, Equatable {
    case bundled
    case directory(URL)

    /// Resolve a `<name>.<ext>` asset to a concrete file URL, or `nil` if it
    /// isn't present at this location. Callers translate `nil` into the
    /// loader-specific "asset missing" error.
    func fileURL(name: String, ext: String) -> URL? {
        switch self {
        case .bundled:
            return Bundle.main.url(forResource: name, withExtension: ext)
        case .directory(let dir):
            let candidate = dir.appendingPathComponent("\(name).\(ext)")
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }
    }
}
