import AVFoundation
import Foundation
import MLX

/// On-device Whisper transcriber. T1.1b-4 wired the file-based path end-to-end
/// (`PCM → mel → encoder → greedy decode → tokenizer decode`). The streaming
/// path still throws `engineNotImplemented` — recorder integration arrives in T1.2d.
///
/// **Actor, since T1.2c.** The loaded `WhisperModel` / `WhisperTokenizer` /
/// mel filterbank are cached across calls (was: fresh load per call, ~30 ms +
/// Metal shader JIT), and actor isolation is what makes that cached
/// non-Sendable MLX state safe behind the `Sendable` `Transcriber` protocol.
/// A side effect worth keeping: transcribe calls serialize through the actor,
/// which is the right behavior for a GPU-bound single-model engine anyway.
///
/// Note on isolation: this type needs no `nonisolated` markers despite the
/// project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — actor members are
/// exempt from default isolation (SE-0466). That only holds because
/// `Transcriber` is a `nonisolated protocol`; an implicitly-`@MainActor`
/// protocol would propagate `@MainActor` onto the synchronous `init` via
/// conformance inference (see the note on `Transcriber` and CHANGE_LOG
/// 2026-06-11).
actor WhisperMLXTranscriber: Transcriber {
    /// Everything `transcribe` needs, loaded as a unit from one location.
    /// Single-entry cache by design: two `small.en` models resident would be
    /// ~1 GB of fp16 weights — never useful on the target device.
    struct LoadedAssets {
        let location: WhisperModelLocation
        let model: WhisperModel
        let tokenizer: WhisperTokenizer
        let melFilters: MLXArray
    }

    /// Where to load from when no store is injected or the store's download
    /// isn't usable. `.bundled` keeps the dev path working (weights fetched
    /// via `scripts/fetch-whisper-model.sh`).
    private let fallbackLocation: WhisperModelLocation

    /// T1.2b's download owner. Optional: dev builds and unit tests construct
    /// the transcriber without one.
    private let store: WhisperModelStore?

    private var cache: LoadedAssets?

    init(store: WhisperModelStore? = nil, fallbackLocation: WhisperModelLocation = .bundled) {
        self.store = store
        self.fallbackLocation = fallbackLocation
    }

    /// Resolved fresh on every call — never latched — so a model downloaded
    /// (or deleted) mid-session takes effect on the next transcription.
    func resolveLocation() async -> WhisperModelLocation {
        guard let store else { return fallbackLocation }
        return await store.activeLocation ?? fallbackLocation
    }

    /// Returns the cached assets for `location`, loading (and replacing any
    /// previously cached location's assets) on miss.
    func assets(at location: WhisperModelLocation) throws -> LoadedAssets {
        if let cache, cache.location == location { return cache }
        // Release the old model before loading the new one so both weight
        // sets are never resident at once.
        cache = nil
        let model = try WhisperModel.load(from: location)
        let tokenizer = try WhisperTokenizer(location: location)
        let melFilters = try WhisperAudio.melFilters(nMels: model.dims.n_mels, from: location)
        let loaded = LoadedAssets(
            location: location,
            model: model,
            tokenizer: tokenizer,
            melFilters: melFilters
        )
        cache = loaded
        return loaded
    }

    func transcribe(_ audio: URL, options: TranscriptionOptions) async throws -> String {
        guard case .whisperMLX = options else {
            preconditionFailure(
                "WhisperMLXTranscriber received non-whisperMLX options — factory and engine selection are out of sync")
        }

        let pcm = try WhisperAudio.loadPCM(url: audio)
        let assets = try assets(at: await resolveLocation())

        // T1.2d-1: long audio is walked in 30-s windows with timestamp-guided
        // seek (the reference's `transcribe.py` loop, model-agnostic half in
        // `ChunkedTranscription`). Each window decodes independently — the
        // reference's `condition_on_previous_text` is deliberately not ported
        // (it's the known repetition-loop failure source and needs the
        // temperature-fallback machinery we don't have).
        return ChunkedTranscription.run(pcm: pcm, window: .whisper) { slice in
            decodeOneWindow(slice, assets: assets)
        }
    }

    /// One window: pad/trim to the encoder's 30 s, build the log-mel from the
    /// cached filterbank, cast to fp16 to match the weight dtype (avoids
    /// mid-graph promotion to fp32), encode, greedy-decode with timestamp
    /// rules, then either skip the window as silence or hand the timestamp
    /// analysis to `parseWindow` for text + seek advance. (`eval` below is
    /// `MLX.eval(_:)` — forces the lazy tensor graph, not code evaluation.)
    private func decodeOneWindow(_ samples: ArraySlice<Float>, assets: LoadedAssets) -> WindowDecodeResult {
        let audioArr = WhisperAudio.padOrTrim(MLXArray(Array(samples)))
        let mel = WhisperAudio.logMelSpectrogram(audio: audioArr, filters: assets.melFilters)
            .asType(.float16)
        let melBatch = expandedDimensions(mel, axis: 0)
        let features = assets.model.embedAudio(melBatch)
        eval(features)

        let decoded = WhisperDecoding.decodeWindow(model: assets.model, audioFeatures: features)

        // No-voice-activity skip, with the reference's logprob override:
        // confident decodes survive a high no-speech probability.
        if decoded.noSpeechProb > WhisperDecoding.noSpeechThreshold
            && decoded.avgLogprob <= WhisperDecoding.logprobThreshold {
            return WindowDecodeResult(text: "", advance: .fullWindow)
        }

        let parsed = WhisperDecoding.parseWindow(decoded.tokens)
        return WindowDecodeResult(
            text: assets.tokenizer.decode(parsed.contentTokens),
            advance: parsed.advance
        )
    }

    func makeStreamingSession(options: TranscriptionOptions) async throws -> any TranscriptionSession {
        guard case .whisperMLX = options else {
            preconditionFailure(
                "WhisperMLXTranscriber received non-whisperMLX options — factory and engine selection are out of sync")
        }
        throw TranscriptionError.engineNotImplemented(
            "On-device Whisper streaming arrives in T1.2d — for now, Apple Speech is the streaming engine."
        )
    }
}
