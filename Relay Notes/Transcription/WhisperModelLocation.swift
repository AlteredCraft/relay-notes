import Foundation

/// Where the Whisper asset bundle (config + tokenizer + mel filters + weights)
/// lives at load time.
///
/// - `.bundled` — flat at the `.app` root (dev builds only; the 481 MB
///   `weights.safetensors` is gitignored and fetched via
///   `scripts/fetch-whisper-model.sh`). File lookup goes through
///   `Bundle.main.url(forResource:withExtension:)` and intentionally ignores
///   any subdirectory layout — Xcode's file-system-synchronized group flattens
///   the resources at build time (see CLAUDE.md).
/// - `.directory(URL)` — a real on-disk directory (T1.2 will use
///   `Application Support/whisper/small.en/`). File lookup is
///   `dir.appendingPathComponent("<name>.<ext>")`.
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
