import Foundation
import Observation

/// Registry of the per-engine downloadable-model stores, and the single source of
/// truth for **per-engine readiness** (T2.3). Replaces the old single
/// `whisperReady: Bool` that hardcoded one model-backed engine: gating now asks
/// the registry `isReady(_:)` per engine, so a second on-device engine (Parakeet,
/// T2.5) drops in by adding a store + a `store(for:)` arm — no new gating Bool.
///
/// `@Observable` so SwiftUI surfaces (the Settings engine buttons, the
/// `NoteDetailView` re-transcribe menu) re-render when a model is downloaded or
/// deleted — they read `isReady(_:)` / `readyEngines`, which reach through to the
/// observed `DownloadableModelStore.status`.
///
/// One instance is constructed in `ContentView` and shared by everything that
/// needs model presence: the recorder's launch reconcile, the `TranscriberFactory`
/// (so a transcriber loads from the same downloaded directory), `ReTranscriber`,
/// and `SettingsView`.
@MainActor
@Observable
final class ModelStores {
    /// Backing store for the Whisper (small.en) MLX engine.
    let whisper: WhisperModelStore
    /// Backing store for the Parakeet (TDT 0.6b) MLX engine.
    let parakeet: ParakeetModelStore
    /// The L2 cleanup (LLM) model store. Not a `TranscriptionEngine`, so it's a
    /// sibling here — outside the engine `store(for:)` / `readyEngines` machinery —
    /// but it shares this registry as the one place the app gets model presence.
    /// Cleanup gating reads `cleanup.status` directly (see `NoteDetailView`).
    let cleanup: CleanupModelStore

    /// Builds the registry, defaulting any store the caller leaves out to the real
    /// Application-Support-backed one. Production calls `ModelStores()` (all
    /// defaulted); tests pass only the slots they pin to a temp directory — e.g.
    /// `ModelStores(whisper:)` for deterministic Whisper readiness, or the
    /// all-explicit form to assert "a ready cleanup model is excluded from engine
    /// gating" (the design choice this registry encodes).
    ///
    /// The slots are `nil`-defaulted rather than `= WhisperModelStore()`-defaulted
    /// because a non-`nil` default is evaluated in a nonisolated context and can't
    /// call the `@MainActor` store init; the `??` fallbacks run in this `@MainActor`
    /// init body, where constructing a store is fine.
    init(
        whisper: WhisperModelStore? = nil,
        parakeet: ParakeetModelStore? = nil,
        cleanup: CleanupModelStore? = nil
    ) {
        self.whisper = whisper ?? WhisperModelStore()
        self.parakeet = parakeet ?? ParakeetModelStore()
        self.cleanup = cleanup ?? CleanupModelStore()
    }

    /// The download store backing `engine`, or `nil` for engines with no
    /// downloadable model (Apple Speech ships with the OS). The compiler-enforced
    /// switch is the one place the engine ↔ store mapping lives.
    func store(for engine: TranscriptionEngine) -> DownloadableModelStore? {
        switch engine {
        case .apple: return nil
        case .whisperMLX: return whisper
        case .parakeetMLX: return parakeet
        }
    }

    /// Whether `engine` can be selected/used right now: an engine with no model
    /// (Apple) is always ready; a model-backed engine only when its store reports
    /// `.ready`.
    func isReady(_ engine: TranscriptionEngine) -> Bool {
        guard let store = store(for: engine) else { return true }
        return store.status == .ready
    }

    /// Engines selectable right now — Apple always, plus any model-backed engine
    /// whose weights are present on disk. Fed to
    /// `Tunings.reconcileEngineAvailability(readyEngines:)`.
    var readyEngines: Set<TranscriptionEngine> {
        Set(TranscriptionEngine.allCases.filter { isReady($0) })
    }
}
