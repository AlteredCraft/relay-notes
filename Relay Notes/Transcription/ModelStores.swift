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
    let whisper: WhisperModelStore

    init() {
        self.whisper = WhisperModelStore()
    }

    /// Explicit stores — for tests (e.g. a store bound to a temp directory).
    init(whisper: WhisperModelStore) {
        self.whisper = whisper
    }

    /// The download store backing `engine`, or `nil` for engines with no
    /// downloadable model (Apple Speech ships with the OS). The compiler-enforced
    /// switch is the one place the engine ↔ store mapping lives.
    func store(for engine: TranscriptionEngine) -> DownloadableModelStore? {
        switch engine {
        case .apple: return nil
        case .whisperMLX: return whisper
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
