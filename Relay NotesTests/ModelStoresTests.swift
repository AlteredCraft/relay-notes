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
}
