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

    // MARK: - readyEngines

    @Test func readyEnginesExcludesWhisperWhenMissing() {
        let (stores, dir) = missingWhisperStores()
        defer { cleanup(dir) }
        #expect(stores.readyEngines == [.apple])
    }

    @Test func readyEnginesIncludesWhisperWhenPresent() {
        let (stores, dir) = readyWhisperStores()
        defer { cleanup(dir) }
        #expect(stores.readyEngines == [.apple, .whisperMLX])
    }
}
