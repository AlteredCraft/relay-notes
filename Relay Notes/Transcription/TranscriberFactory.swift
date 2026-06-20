import Foundation

/// Resolves the runtime `Transcriber` impl for a given `TranscriptionEngine`.
/// Instances are cached — load-bearing for the MLX engines, whose instance holds
/// hundreds of MB / GBs of model weights across calls (T1.2c).
///
/// **At most one live MLX-backed transcriber (T2.4).** Whisper (~0.5 GB resident)
/// and Parakeet (~1.2 GB) are never used at the same time, so keeping both
/// resident would waste >1.5 GB on the 8 GB device for no benefit. Switching to a
/// *different* MLX engine evicts the previous one's cached instance — dropping the
/// factory's only strong reference so its weights (and the actor) can be released —
/// before constructing the new one. Apple Speech is not MLX-backed and is cached
/// independently, so toggling Apple↔an MLX engine doesn't churn the loaded model.
@MainActor
final class TranscriberFactory {
    private let locale: Locale
    /// The per-engine model stores, handed to the MLX transcribers so they load
    /// from the downloaded directory. `nil` (dev, tests) → bundled/fallback only.
    private let stores: ModelStores?
    private var appleSpeech: AppleSpeechTranscriber?
    /// The single live MLX transcriber, tagged with the engine it serves. Holds
    /// at most one entry (Whisper *or* Parakeet, never both).
    private var liveMLX: (engine: TranscriptionEngine, transcriber: any Transcriber)?

    init(locale: Locale = .current, stores: ModelStores? = nil) {
        self.locale = locale
        self.stores = stores
    }

    /// The cached `Transcriber` for `engine`, constructing it on first request.
    /// Apple Speech is cached independently; the two MLX engines share a single
    /// slot, so selecting one evicts the other (see `liveMLXTranscriber`).
    func transcriber(for engine: TranscriptionEngine) -> any Transcriber {
        switch engine {
        case .apple:
            if let appleSpeech { return appleSpeech }
            let new = AppleSpeechTranscriber(locale: locale)
            appleSpeech = new
            return new
        case .whisperMLX:
            return liveMLXTranscriber(for: engine) {
                WhisperMLXTranscriber(store: stores?.whisper)
            }
        case .parakeetMLX:
            return liveMLXTranscriber(for: engine) {
                ParakeetMLXTranscriber(store: stores?.parakeet)
            }
        }
    }

    /// Returns the cached MLX transcriber for `engine`, or builds it via `make` —
    /// first **evicting any other MLX engine's live instance** so two MLX models
    /// are never resident at once (T2.4). Re-requesting the *same* MLX engine
    /// returns the cached instance (keeps its loaded weights).
    private func liveMLXTranscriber(
        for engine: TranscriptionEngine, _ make: () -> any Transcriber
    ) -> any Transcriber {
        if let liveMLX, liveMLX.engine == engine { return liveMLX.transcriber }
        // Drop the prior MLX engine's instance (the factory's only strong ref) so
        // its ~GB of weights release before the new model loads.
        liveMLX = nil
        let new = make()
        liveMLX = (engine, new)
        return new
    }
}
