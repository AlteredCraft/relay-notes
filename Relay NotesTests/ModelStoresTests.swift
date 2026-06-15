import Foundation
import Testing
@testable import Relay_Notes

/// Tests for `ModelStores` — the per-engine model-readiness registry that
/// replaced the single `whisperReady: Bool` in T2.3. This is the single source of
/// truth for engine availability; `ReTranscriber.availableEngines`,
/// `SettingsView`'s engine buttons, and the launch reconcile all read through it.
///
/// Simulator-safe: pure disk-presence checks (a placeholder weights file makes a
/// store report `.ready`), no MLX load.
@MainActor
struct ModelStoresTests {

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStoresTests.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Whisper store backed by an empty dir → `.missing`.
    private func missingWhisperStores() -> (stores: ModelStores, dir: URL) {
        let dir = makeTempDirectory()
        return (ModelStores(whisper: WhisperModelStore(modelDirectory: dir)), dir)
    }

    /// Whisper store backed by a dir containing a placeholder weights file → `.ready`.
    private func readyWhisperStores() -> (stores: ModelStores, dir: URL) {
        let dir = makeTempDirectory()
        try? Data("not-real-weights".utf8).write(to: dir.appendingPathComponent("weights.safetensors"))
        return (ModelStores(whisper: WhisperModelStore(modelDirectory: dir)), dir)
    }

    /// Parakeet store backed by an empty dir → `.missing`.
    private func missingParakeetStores() -> (stores: ModelStores, dir: URL) {
        let dir = makeTempDirectory()
        return (ModelStores(parakeet: ParakeetModelStore(modelDirectory: dir)), dir)
    }

    /// Parakeet store backed by a dir with placeholder files for *both* remote
    /// files (the spec requires `model.safetensors` **and** `config.json`) → `.ready`.
    private func readyParakeetStores() -> (stores: ModelStores, dir: URL) {
        let dir = makeTempDirectory()
        try? Data("not-real-weights".utf8).write(to: dir.appendingPathComponent("model.safetensors"))
        try? Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        return (ModelStores(parakeet: ParakeetModelStore(modelDirectory: dir)), dir)
    }

    // MARK: - isReady

    @Test func appleIsAlwaysReady() {
        let (stores, dir) = missingWhisperStores()
        defer { cleanup(dir) }
        #expect(stores.isReady(.apple))
    }

    @Test func whisperNotReadyWhenModelMissing() {
        let (stores, dir) = missingWhisperStores()
        defer { cleanup(dir) }
        #expect(!stores.isReady(.whisperMLX))
    }

    @Test func whisperReadyWhenModelPresent() {
        let (stores, dir) = readyWhisperStores()
        defer { cleanup(dir) }
        #expect(stores.isReady(.whisperMLX))
    }

    @Test func parakeetNotReadyWhenModelMissing() {
        let (stores, dir) = missingParakeetStores()
        defer { cleanup(dir) }
        #expect(!stores.isReady(.parakeetMLX))
    }

    @Test func parakeetReadyWhenBothFilesPresent() {
        let (stores, dir) = readyParakeetStores()
        defer { cleanup(dir) }
        #expect(stores.isReady(.parakeetMLX))
    }

    @Test func parakeetNotReadyWithOnlyWeights() {
        // The spec requires both remote files; weights alone isn't ready.
        let dir = makeTempDirectory()
        defer { cleanup(dir) }
        try? Data("not-real-weights".utf8).write(to: dir.appendingPathComponent("model.safetensors"))
        let stores = ModelStores(parakeet: ParakeetModelStore(modelDirectory: dir))
        #expect(!stores.isReady(.parakeetMLX))
    }

    // MARK: - store(for:)

    @Test func appleHasNoStore() {
        let (stores, dir) = missingWhisperStores()
        defer { cleanup(dir) }
        #expect(stores.store(for: .apple) == nil)
    }

    @Test func whisperResolvesToWhisperStore() {
        let (stores, dir) = missingWhisperStores()
        defer { cleanup(dir) }
        #expect(stores.store(for: .whisperMLX) === stores.whisper)
    }

    @Test func parakeetResolvesToParakeetStore() {
        let (stores, dir) = missingParakeetStores()
        defer { cleanup(dir) }
        #expect(stores.store(for: .parakeetMLX) === stores.parakeet)
    }

    // MARK: - readyEngines
    //
    // Both stores pinned to temp dirs so readiness is deterministic (independent
    // of any model the simulator's Application Support happens to hold).

    @Test func readyEnginesIsAppleOnlyWhenBothModelsMissing() {
        let wDir = makeTempDirectory(); let pDir = makeTempDirectory()
        defer { cleanup(wDir); cleanup(pDir) }
        let stores = ModelStores(
            whisper: WhisperModelStore(modelDirectory: wDir),
            parakeet: ParakeetModelStore(modelDirectory: pDir))
        #expect(stores.readyEngines == [.apple])
    }

    @Test func readyEnginesIncludesWhisperWhenOnlyWhisperPresent() {
        let wDir = makeTempDirectory(); let pDir = makeTempDirectory()
        defer { cleanup(wDir); cleanup(pDir) }
        try? Data("not-real-weights".utf8).write(to: wDir.appendingPathComponent("weights.safetensors"))
        let stores = ModelStores(
            whisper: WhisperModelStore(modelDirectory: wDir),
            parakeet: ParakeetModelStore(modelDirectory: pDir))
        #expect(stores.readyEngines == [.apple, .whisperMLX])
    }

    @Test func readyEnginesIncludesBothWhenBothPresent() {
        let wDir = makeTempDirectory(); let pDir = makeTempDirectory()
        defer { cleanup(wDir); cleanup(pDir) }
        try? Data("not-real-weights".utf8).write(to: wDir.appendingPathComponent("weights.safetensors"))
        try? Data("not-real-weights".utf8).write(to: pDir.appendingPathComponent("model.safetensors"))
        try? Data("{}".utf8).write(to: pDir.appendingPathComponent("config.json"))
        let stores = ModelStores(
            whisper: WhisperModelStore(modelDirectory: wDir),
            parakeet: ParakeetModelStore(modelDirectory: pDir))
        #expect(stores.readyEngines == [.apple, .whisperMLX, .parakeetMLX])
    }

    // MARK: - Cleanup-store wiring (GH #13)
    //
    // The L2 cleanup store is a sibling in the registry but is **not** a
    // `TranscriptionEngine`: it must be reachable for cleanup gating yet stay out of
    // the engine `store(for:)` / `readyEngines` machinery. A future refactor could
    // silently fold it into engine gating, so these pin the exclusion.

    /// A cleanup store backed by a dir holding placeholders for every spec remote
    /// file → `.ready` (matches `CleanerTests`' readiness setup).
    private func readyCleanupStore(in dir: URL) -> CleanupModelStore {
        for file in ModelDownloadSpec.gemmaCleanupE2B.remoteFiles {
            try? Data("x".utf8).write(to: dir.appendingPathComponent(file.destFilename))
        }
        let store = CleanupModelStore(modelDirectory: dir)
        store.refreshStatus()
        return store
    }

    @Test func cleanupStoreReachableViaInit() {
        let dir = makeTempDirectory()
        defer { cleanup(dir) }
        let store = CleanupModelStore(modelDirectory: dir)
        let stores = ModelStores(cleanup: store)
        #expect(stores.cleanup === store)
    }

    @Test func cleanupStoreIsNotReachableViaStoreForAnyEngine() {
        let dir = makeTempDirectory()
        defer { cleanup(dir) }
        let stores = ModelStores(cleanup: CleanupModelStore(modelDirectory: dir))
        // No engine resolves to the cleanup store — it's outside the engine mapping.
        for engine in TranscriptionEngine.allCases {
            #expect(stores.store(for: engine) !== stores.cleanup)
        }
    }

    @Test func readyCleanupModelIsExcludedFromReadyEngines() {
        // Both transcription engines pinned to empty temp dirs (→ not ready) while
        // the cleanup model IS ready. A ready cleanup model must not inflate
        // `readyEngines` — it isn't a selectable transcription engine.
        let wDir = makeTempDirectory(); let pDir = makeTempDirectory(); let cDir = makeTempDirectory()
        defer { cleanup(wDir); cleanup(pDir); cleanup(cDir) }
        let cleanupStore = readyCleanupStore(in: cDir)
        let stores = ModelStores(
            whisper: WhisperModelStore(modelDirectory: wDir),
            parakeet: ParakeetModelStore(modelDirectory: pDir),
            cleanup: cleanupStore)
        #expect(stores.cleanup.status == .ready)  // exclusion is meaningful, not vacuous
        #expect(stores.readyEngines == [.apple])
    }
}
