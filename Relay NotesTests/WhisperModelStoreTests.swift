import CryptoKit
import Foundation
import Testing
@testable import Relay_Notes

/// Tests for the on-disk-presence and asset-staging surface of
/// `WhisperModelStore`. The actual URL download path is **not** exercised here
/// — that's smoke-test territory (481 MB over the wire, integrity-check the
/// real HF file). These tests focus on:
///   - status detection from disk presence
///   - `stageBundledAssets` copies bundle → model directory
///   - `delete` removes everything cleanly
///   - the SHA-256 helper hashes correctly against a CryptoKit reference
@MainActor
struct WhisperModelStoreTests {

    /// Allocates a unique temporary directory for each test so they don't
    /// trample each other. Cleaned up at test exit (best effort).
    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperModelStoreTests.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test
    func emptyDirectoryReportsMissing() {
        let tmp = makeTempDirectory()
        defer { cleanup(tmp) }
        let store = WhisperModelStore(modelDirectory: tmp)
        #expect(store.status == .missing)
    }

    @Test
    func presentWeightsReportReady() throws {
        let tmp = makeTempDirectory()
        defer { cleanup(tmp) }
        let weights = tmp.appendingPathComponent("weights.safetensors")
        try Data("not-real-weights".utf8).write(to: weights)
        let store = WhisperModelStore(modelDirectory: tmp)
        #expect(store.status == .ready)
    }

    @Test
    func locationPointsAtModelDirectory() {
        let tmp = makeTempDirectory()
        defer { cleanup(tmp) }
        let store = WhisperModelStore(modelDirectory: tmp)
        guard case let .directory(url) = store.location else {
            Issue.record("Expected .directory location")
            return
        }
        #expect(url == tmp)
    }

    @Test
    func stageBundledAssetsCopiesAllThreeFiles() throws {
        let tmp = makeTempDirectory()
        defer { cleanup(tmp) }
        let store = WhisperModelStore(modelDirectory: tmp)

        try store.stageBundledAssets()

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: tmp.appendingPathComponent("config.json").path))
        #expect(fm.fileExists(atPath: tmp.appendingPathComponent("gpt2.tiktoken").path))
        #expect(fm.fileExists(atPath: tmp.appendingPathComponent("mel_filters.safetensors").path))
    }

    @Test
    func stageBundledAssetsIsIdempotent() throws {
        let tmp = makeTempDirectory()
        defer { cleanup(tmp) }
        let store = WhisperModelStore(modelDirectory: tmp)

        try store.stageBundledAssets()
        // Mutate the staged file to confirm the second call overwrites.
        let configURL = tmp.appendingPathComponent("config.json")
        try Data("tampered".utf8).write(to: configURL)
        try store.stageBundledAssets()

        let restored = try Data(contentsOf: configURL)
        #expect(restored != Data("tampered".utf8))
    }

    @Test
    func deleteRemovesModelDirectoryAndFlipsStatusToMissing() throws {
        let tmp = makeTempDirectory()
        defer { cleanup(tmp) }
        let store = WhisperModelStore(modelDirectory: tmp)
        try store.stageBundledAssets()
        try Data("placeholder".utf8).write(to: tmp.appendingPathComponent("weights.safetensors"))
        store.refreshStatus()
        #expect(store.status == .ready)

        try store.delete()

        #expect(store.status == .missing)
        #expect(!FileManager.default.fileExists(atPath: tmp.path))
    }

    @Test
    func sha256HelperMatchesCryptoKit() throws {
        let tmp = makeTempDirectory()
        defer { cleanup(tmp) }
        let file = tmp.appendingPathComponent("payload.bin")
        // Make the payload bigger than the 1 MB read chunk so we exercise
        // the streaming-update path, not just a single update.
        let chunk = Data(repeating: 0xAB, count: 1 << 20)
        let payload = chunk + Data(repeating: 0xCD, count: 4_321)
        try payload.write(to: file)

        let ours = try WhisperModelStore.sha256Hex(of: file)
        let theirs = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        #expect(ours == theirs)
    }

    @Test
    func downloadURLIsPinnedToCommitSHA() {
        // The whole point of the pin is that the URL contains a specific
        // commit hash, not the mutable `main` ref. Catch accidental
        // un-pinning.
        let urlString = WhisperModelStore.downloadURL.absoluteString
        #expect(urlString.contains("/resolve/f8ff44ec66c4b1748fb2e3eb13b3b521a0bdfea8/"))
        #expect(!urlString.contains("/resolve/main/"))
    }
}
