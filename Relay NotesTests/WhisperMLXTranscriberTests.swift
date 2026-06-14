import AVFoundation
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

        let factory = TranscriberFactory(stores: ModelStores(whisper: store))
        let transcriber = try #require(factory.transcriber(for: .whisperMLX) as? WhisperMLXTranscriber)
        let location = await transcriber.resolveLocation()
        #expect(location == .directory(tmp))
    }

    // MARK: - Streaming session (T1.2d-2, simulator-safe — no MLX until finish)

    @Test
    func makeStreamingSessionReturnsWhisperSession() async throws {
        let transcriber = WhisperMLXTranscriber()
        let session = try await transcriber.makeStreamingSession(options: .whisperMLX)
        #expect(session is WhisperStreamingSession)
    }

    @Test
    func sessionReportsWhisperModelProvenance() {
        // The session is the authority on what produced the transcript;
        // RecorderViewModel persists this onto the Note for the detail view.
        let session = WhisperStreamingSession(transcriber: WhisperMLXTranscriber())
        #expect(session.modelDescription == WhisperMLXTranscriber.modelDescription)
        #expect(session.modelDescription.contains("small.en"))
    }

    @Test
    func sessionRequestsWhisperNativeAudioFormat() async throws {
        // 16 kHz mono Float32 — this is what makes LiveAudioEngine's converter
        // deliver mel-pipeline-ready buffers, with no resample at finish time.
        let session = WhisperStreamingSession(transcriber: WhisperMLXTranscriber())
        let format = try #require(session.audioFormat)
        #expect(format.sampleRate == 16_000)
        #expect(format.channelCount == 1)
        #expect(format.commonFormat == .pcmFormatFloat32)
    }

    @Test
    func feedAccumulatesSamplesAcrossBuffers() throws {
        let session = WhisperStreamingSession(transcriber: WhisperMLXTranscriber())
        session.feed(try makePCMBuffer(frames: 4_096))
        session.feed(try makePCMBuffer(frames: 1_024))
        #expect(session.bufferedSampleCount == 5_120)
    }

    @Test
    func feedIgnoresEmptyBuffers() throws {
        let session = WhisperStreamingSession(transcriber: WhisperMLXTranscriber())
        session.feed(try makePCMBuffer(frames: 0))
        #expect(session.bufferedSampleCount == 0)
    }

    @Test
    func cancelDropsBufferAndFinishesUpdates() async throws {
        let session = WhisperStreamingSession(transcriber: WhisperMLXTranscriber())
        session.feed(try makePCMBuffer(frames: 2_048))
        await session.cancel()
        #expect(session.bufferedSampleCount == 0)

        // The updates stream must complete without ever yielding — the
        // zero-partials contract.
        for await _ in session.updates {
            Issue.record("Whisper session must not emit partials")
        }
    }

    private func makePCMBuffer(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1)))
        buffer.frameLength = frames
        return buffer
    }

    // MARK: - Asset caching (device-only — loads real weights via MLX)

    #if !targetEnvironment(simulator)
    @Test
    func assetsAreCachedAcrossCalls() async throws {
        // Weights are download-only (no longer bundled), so this manual device
        // probe needs the model already downloaded via Settings. Skip cleanly
        // when it isn't present rather than failing on missing weights.
        let store = WhisperModelStore()
        guard store.status == .ready else { return }
        let transcriber = WhisperMLXTranscriber(store: store)
        let location = await transcriber.resolveLocation()
        let reused = try await transcriber.cacheReusesInstances(at: location)
        #expect(reused)
    }
    #endif
}

/// Test-only probe that runs *inside* the actor, so the non-Sendable cached
/// state (`WhisperModel`, `MLXArray`) never crosses the isolation boundary.
extension WhisperMLXTranscriber {
    func cacheReusesInstances(at location: ModelLocation) throws -> Bool {
        let first = try assets(at: location)
        let second = try assets(at: location)
        return first.model === second.model && first.tokenizer === second.tokenizer
    }
}
