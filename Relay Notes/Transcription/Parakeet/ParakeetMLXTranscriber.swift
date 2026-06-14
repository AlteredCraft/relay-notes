import AVFoundation
import Foundation
import MLX

/// On-device Parakeet (TDT 0.6b v2) transcriber — the second MLX engine behind the
/// `Transcriber` protocol (T2.5). Wires the file-based and streaming paths to the
/// device-validated model port (`ParakeetTDTModel`): `PCM → log-mel → FastConformer
/// encoder → TDT greedy decode → vocab decode`, with long-audio chunking.
///
/// **Actor**, like `WhisperMLXTranscriber` and for the same reasons: the loaded
/// `ParakeetTDTModel` + mel filterbank are cached across calls (the load is the
/// §3.1 incremental bf16 cast-release — seconds, not free), and actor isolation is
/// what makes that cached non-`Sendable` MLX state safe behind the `Sendable`
/// `Transcriber` protocol. Transcribe calls serialize through the actor, the right
/// behavior for a GPU-bound single-model engine. (Members need no `nonisolated`
/// markers: actor members are exempt from the project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` per SE-0466, which holds because
/// `Transcriber` is a `nonisolated protocol`.)
actor ParakeetMLXTranscriber: Transcriber {
    /// Provenance label persisted on the `Note` (via the streaming session's
    /// `modelDescription`). `nonisolated static` so the session reads it without
    /// awaiting the actor.
    nonisolated static let modelDescription = "Parakeet (tdt-0.6b-v2)"

    /// Everything `transcribe` needs, loaded as a unit from one directory and
    /// cached. Single-entry by design — one ~1.2 GB bf16 model is the most we keep
    /// resident (and the factory evicts the *other* MLX engine, T2.4).
    struct LoadedAssets {
        let location: ModelLocation
        let model: ParakeetTDTModel
        let preprocessor: ParakeetPreprocessConfig
        /// Cached mel filterbank — building it is a host loop not worth repeating
        /// per call (`ParakeetAudio.melFilterbank`).
        let filters: MLXArray
    }

    /// T2.2's download owner. Optional: dev builds and unit tests construct the
    /// transcriber without one (Parakeet bundles nothing, so there's no fallback —
    /// transcribe throws `.modelUnavailable` if no store resolves a directory).
    private let store: ParakeetModelStore?

    private var cache: LoadedAssets?

    init(store: ParakeetModelStore? = nil) {
        self.store = store
    }

    /// Resolved fresh on every call — never latched — so a model downloaded (or
    /// deleted) mid-session takes effect on the next transcription. `nil` when no
    /// usable download exists (Parakeet has no bundled fallback).
    func resolveLocation() async -> ModelLocation? {
        await store?.activeLocation
    }

    /// Returns the cached assets for `location`, loading (and replacing any
    /// previously cached location's assets) on miss. Throws `.modelUnavailable` if
    /// the directory is missing the config or weights.
    func assets(at location: ModelLocation) throws -> LoadedAssets {
        if let cache, cache.location == location { return cache }
        // Release the old model before loading the new one so two weight sets are
        // never resident at once.
        cache = nil
        guard let configURL = location.fileURL(name: "config", ext: "json"),
              let weightsURL = location.fileURL(name: "model", ext: "safetensors") else {
            throw TranscriptionError.modelUnavailable
        }
        let config = try ParakeetTDTConfig.load(from: configURL)
        let model = try ParakeetTDTModel.load(weightsURL: weightsURL, config: config)
        let filters = ParakeetAudio.melFilterbank(config: config.preprocessor)
        MLX.eval(filters)
        let loaded = LoadedAssets(
            location: location,
            model: model,
            preprocessor: config.preprocessor,
            filters: filters
        )
        cache = loaded
        return loaded
    }

    func transcribe(_ audio: URL, options: TranscriptionOptions) async throws -> String {
        guard case .parakeetMLX = options else {
            preconditionFailure(
                "ParakeetMLXTranscriber received non-parakeetMLX options — factory and engine selection are out of sync")
        }
        let pcm = try WhisperAudio.loadPCM(url: audio)
        return try await transcribePCM(pcm)
    }

    /// Shared by the file path above and `ParakeetStreamingSession.finish()`.
    /// Drives `transcribeChunked` (whole-clip fast path for short notes; overlap +
    /// token merge for long audio — T2.1e) at the production 120 s / 15 s window.
    func transcribePCM(_ pcm: [Float]) async throws -> String {
        guard let location = await resolveLocation() else {
            throw TranscriptionError.modelUnavailable
        }
        let assets = try assets(at: location)
        return assets.model.transcribeChunked(
            MLXArray(pcm),
            preprocessor: assets.preprocessor,
            filters: assets.filters
        )
    }

    /// Hands back an accumulate-then-decode session (zero live partials — Parakeet
    /// has no streaming decode for v1, like Whisper). The model-presence guard is
    /// the Settings gating + launch reconcile (a Parakeet session only starts when
    /// the store is `.ready`); `transcribePCM` still throws `.modelUnavailable`
    /// defensively if the model vanishes mid-session.
    func makeStreamingSession(options: TranscriptionOptions) async throws -> any TranscriptionSession {
        guard case .parakeetMLX = options else {
            preconditionFailure(
                "ParakeetMLXTranscriber received non-parakeetMLX options — factory and engine selection are out of sync")
        }
        return ParakeetStreamingSession(transcriber: self)
    }
}
