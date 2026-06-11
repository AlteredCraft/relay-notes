import Foundation
import Testing
@testable import Relay_Notes

/// Tests for the T1.2c surface of `WhisperMLXTranscriber`: store-driven
/// location resolution (simulator-safe — never touches MLX) and loaded-asset
/// caching (device-only — loads real weights through MLX, gated per the
/// convention in CLAUDE.md).
@MainActor
struct WhisperMLXTranscriberTests {

    /// Allocates a unique temporary directory for each test so they don't
    /// trample each other. Cleaned up at test exit (best effort).
    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperMLXTranscriberTests.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Drops a placeholder weights file so the store reports `.ready` —
    /// resolution only checks presence, never loads the weights.
    private func makeReadyStore(in directory: URL) throws -> WhisperModelStore {
        let weights = directory.appendingPathComponent("weights.safetensors")
        try Data("not-real-weights".utf8).write(to: weights)
        return WhisperModelStore(modelDirectory: directory)
    }

    // MARK: - Location resolution (simulator-safe)

    @Test
    func resolvesFallbackWhenNoStoreInjected() async {
        let transcriber = WhisperMLXTranscriber()
        let location = await transcriber.resolveLocation()
        #expect(location == .bundled)
    }

    @Test
    func resolvesFallbackWhenStoreNotReady() async {
        let tmp = makeTempDirectory()
        defer { cleanup(tmp) }
        let store = WhisperModelStore(modelDirectory: tmp)  // empty → .missing
        #expect(store.status == .missing)

        let transcriber = WhisperMLXTranscriber(store: store)
        let location = await transcriber.resolveLocation()
        #expect(location == .bundled)
    }

    @Test
    func resolvesStoreDirectoryWhenReady() async throws {
        let tmp = makeTempDirectory()
        defer { cleanup(tmp) }
        let store = try makeReadyStore(in: tmp)
        #expect(store.status == .ready)

        let transcriber = WhisperMLXTranscriber(store: store)
        let location = await transcriber.resolveLocation()
        #expect(location == .directory(tmp))
    }

    @Test
    func resolutionTracksStoreStatusChanges() async throws {
        // Deleting the model mid-session must flip resolution back to the
        // fallback — the transcriber re-resolves per call, never latches.
        let tmp = makeTempDirectory()
        defer { cleanup(tmp) }
        let store = try makeReadyStore(in: tmp)
        let transcriber = WhisperMLXTranscriber(store: store)
        #expect(await transcriber.resolveLocation() == .directory(tmp))

        try store.delete()
        #expect(await transcriber.resolveLocation() == .bundled)
    }

    @Test
    func factoryInjectsStoreIntoWhisperTranscriber() async throws {
        let tmp = makeTempDirectory()
        defer { cleanup(tmp) }
        let store = try makeReadyStore(in: tmp)

        let factory = TranscriberFactory(whisperModelStore: store)
        let transcriber = try #require(factory.transcriber(for: .whisperMLX) as? WhisperMLXTranscriber)
        let location = await transcriber.resolveLocation()
        #expect(location == .directory(tmp))
    }

    // MARK: - Asset caching (device-only — loads real weights via MLX)

    #if !targetEnvironment(simulator)
    @Test
    func assetsAreCachedAcrossCalls() async throws {
        let transcriber = WhisperMLXTranscriber()
        let reused = try await transcriber.cacheReusesInstances(at: .bundled)
        #expect(reused)
    }
    #endif
}

/// Test-only probe that runs *inside* the actor, so the non-Sendable cached
/// state (`WhisperModel`, `MLXArray`) never crosses the isolation boundary.
extension WhisperMLXTranscriber {
    func cacheReusesInstances(at location: WhisperModelLocation) throws -> Bool {
        let first = try assets(at: location)
        let second = try assets(at: location)
        return first.model === second.model && first.tokenizer === second.tokenizer
    }
}
