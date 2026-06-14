import AVFoundation
import Foundation
import Testing
@testable import Relay_Notes

/// Tests for the T2.5 surface of `ParakeetMLXTranscriber` / `ParakeetStreamingSession`:
/// store-driven location resolution and the accumulate-then-decode streaming session
/// — both **simulator-safe** (they never touch MLX; the decode at `finish()` is
/// device territory, validated via `ParakeetSmoke`). Mirrors
/// `WhisperMLXTranscriberTests`' simulator-safe half.
@MainActor
struct ParakeetStreamingSessionTests {

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParakeetStreamingSessionTests.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Drops placeholder files for *both* remote files so the store reports
    /// `.ready` — resolution only checks presence, never loads weights.
    private func makeReadyStore(in directory: URL) throws -> ParakeetModelStore {
        try Data("not-real-weights".utf8).write(to: directory.appendingPathComponent("model.safetensors"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
        return ParakeetModelStore(modelDirectory: directory)
    }

    // MARK: - Location resolution (simulator-safe)

    @Test
    func resolvesNilWhenNoStoreInjected() async {
        // Parakeet bundles nothing → no fallback; resolveLocation is nil.
        let transcriber = ParakeetMLXTranscriber()
        let location = await transcriber.resolveLocation()
        #expect(location == nil)
    }

    @Test
    func resolvesNilWhenStoreNotReady() async {
        let tmp = makeTempDirectory()
        defer { cleanup(tmp) }
        let store = ParakeetModelStore(modelDirectory: tmp)  // empty → .missing
        #expect(store.status == .missing)

        let transcriber = ParakeetMLXTranscriber(store: store)
        #expect(await transcriber.resolveLocation() == nil)
    }

    @Test
    func resolvesStoreDirectoryWhenReady() async throws {
        let tmp = makeTempDirectory()
        defer { cleanup(tmp) }
        let store = try makeReadyStore(in: tmp)
        #expect(store.status == .ready)

        let transcriber = ParakeetMLXTranscriber(store: store)
        #expect(await transcriber.resolveLocation() == .directory(tmp))
    }

    @Test
    func resolutionTracksStoreStatusChanges() async throws {
        // The transcriber re-resolves per call, never latches — deleting the
        // model mid-session flips resolution back to nil.
        let tmp = makeTempDirectory()
        defer { cleanup(tmp) }
        let store = try makeReadyStore(in: tmp)
        let transcriber = ParakeetMLXTranscriber(store: store)
        #expect(await transcriber.resolveLocation() == .directory(tmp))

        try store.delete()
        #expect(await transcriber.resolveLocation() == nil)
    }

    // MARK: - Streaming session (simulator-safe — no MLX until finish)

    @Test
    func makeStreamingSessionReturnsParakeetSession() async throws {
        let transcriber = ParakeetMLXTranscriber()
        let session = try await transcriber.makeStreamingSession(options: .parakeetMLX)
        #expect(session is ParakeetStreamingSession)
    }

    @Test
    func sessionReportsParakeetModelProvenance() {
        let session = ParakeetStreamingSession(transcriber: ParakeetMLXTranscriber())
        #expect(session.modelDescription == ParakeetMLXTranscriber.modelDescription)
        #expect(session.modelDescription.contains("tdt-0.6b-v2"))
    }

    @Test
    func sessionRequestsParakeetNativeAudioFormat() throws {
        // 16 kHz mono Float32 — LiveAudioEngine's converter delivers mel-ready
        // buffers, no resample at finish time (same as Whisper).
        let session = ParakeetStreamingSession(transcriber: ParakeetMLXTranscriber())
        let format = try #require(session.audioFormat)
        #expect(format.sampleRate == 16_000)
        #expect(format.channelCount == 1)
        #expect(format.commonFormat == .pcmFormatFloat32)
    }

    @Test
    func emitsLivePartialsIsFalse() {
        // Drives the recorder's placeholder card (no live transcript while
        // recording with Parakeet).
        let session = ParakeetStreamingSession(transcriber: ParakeetMLXTranscriber())
        #expect(session.emitsLivePartials == false)
    }

    @Test
    func feedAccumulatesSamplesAcrossBuffers() throws {
        let session = ParakeetStreamingSession(transcriber: ParakeetMLXTranscriber())
        session.feed(try makePCMBuffer(frames: 4_096))
        session.feed(try makePCMBuffer(frames: 1_024))
        #expect(session.bufferedSampleCount == 5_120)
    }

    @Test
    func feedIgnoresEmptyBuffers() throws {
        let session = ParakeetStreamingSession(transcriber: ParakeetMLXTranscriber())
        session.feed(try makePCMBuffer(frames: 0))
        #expect(session.bufferedSampleCount == 0)
    }

    @Test
    func cancelDropsBufferAndFinishesUpdates() async throws {
        let session = ParakeetStreamingSession(transcriber: ParakeetMLXTranscriber())
        session.feed(try makePCMBuffer(frames: 2_048))
        await session.cancel()
        #expect(session.bufferedSampleCount == 0)

        // The updates stream must complete without ever yielding — the
        // zero-partials contract.
        for await _ in session.updates {
            Issue.record("Parakeet session must not emit partials")
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
}
