import Foundation
import Testing
@testable import Relay_Notes

/// Coverage for the generalized `DownloadableModelStore` (T2.2) — the spec data,
/// multi-remote-file readiness, and the Parakeet binding. Simulator-safe (no MLX,
/// no network): the actual download path is smoke-test territory (`ParakeetSmoke`,
/// `MLXSmoke`). The Whisper-specific surface stays covered by `WhisperModelStoreTests`.
@MainActor
struct DownloadableModelStoreTests {

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadableModelStoreTests.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Specs

    @Test
    func parakeetSpecIsPinnedAndSized() {
        let spec = ModelDownloadSpec.parakeetTDT06bV2
        // Two remote files, nothing bundled (config is downloaded, not staged).
        #expect(spec.bundledFiles.isEmpty)
        #expect(spec.remoteFiles.map(\.destFilename).sorted() == ["config.json", "model.safetensors"])

        for file in spec.remoteFiles {
            // Pinned to an immutable commit path, never the mutable `main` ref.
            #expect(file.url.absoluteString.contains("/resolve/b8e276dc1b4645dc90ddb6d7b22fa82e9773f685/"))
            #expect(!file.url.absoluteString.contains("/resolve/main/"))
            #expect(file.sha256.count == 64)  // hex SHA-256
            #expect(file.size > 0)
        }

        let weights = spec.remoteFiles.first { $0.destFilename == "model.safetensors" }
        #expect(weights?.size == 2_471_559_904)  // == the device's 2357 MB on disk
        #expect(weights?.sha256 == "b958c37a6baa6874a279108755c8f2818e27bf647d72d54800a234a421341dfe")
    }

    @Test
    func whisperSpecHasSingleRemoteAndThreeBundled() {
        let spec = ModelDownloadSpec.whisperSmallEn
        #expect(spec.remoteFiles.count == 1)
        #expect(spec.remoteFiles[0].destFilename == "weights.safetensors")
        #expect(spec.bundledFiles.map(\.filename).sorted()
            == ["config.json", "gpt2.tiktoken", "mel_filters.safetensors"])
        #expect(spec.remoteFiles[0].url.absoluteString
            .contains("/resolve/f8ff44ec66c4b1748fb2e3eb13b3b521a0bdfea8/"))
    }

    @Test
    func gemmaCleanupSpecIsPinnedAndComplete() {
        let spec = ModelDownloadSpec.gemmaCleanupE2B
        #expect(spec.bundledFiles.isEmpty)
        // The full snapshot loadContainer(directory:) + AutoTokenizer need.
        #expect(spec.remoteFiles.map(\.destFilename).sorted() == [
            "chat_template.jinja", "config.json", "generation_config.json",
            "model.safetensors", "model.safetensors.index.json",
            "processor_config.json", "tokenizer.json", "tokenizer_config.json",
        ])
        for file in spec.remoteFiles {
            #expect(file.url.absoluteString.contains("/resolve/2c3e507453b4f218d05fe3cc97bea5c5a654257e/"))
            #expect(!file.url.absoluteString.contains("/resolve/main/"))
            #expect(file.sha256.count == 64)
            #expect(file.size > 0)
            // HF filenames kept verbatim so the directory loader/tokenizer find them.
            #expect(file.url.absoluteString.hasSuffix(file.destFilename))
        }
        let weights = spec.remoteFiles.first { $0.destFilename == "model.safetensors" }
        #expect(weights?.size == 3_581_101_896)
        #expect(weights?.sha256 == "e9bea0584546fafb5ff83a1132a6c4662a8498cc6a5bcda52fc6ca562b7bafab")
    }

    // MARK: - Readiness (multi-file)

    @Test
    func parakeetReadyOnlyWhenAllRemoteFilesPresent() throws {
        let tmp = makeTempDirectory()
        defer { cleanup(tmp) }
        let store = ParakeetModelStore(modelDirectory: tmp)
        #expect(store.status == .missing)

        // Only the weights present → still missing (config.json is required).
        try Data("weights".utf8).write(to: tmp.appendingPathComponent("model.safetensors"))
        store.refreshStatus()
        #expect(store.status == .missing)

        // Both remote files present → ready.
        try Data("{}".utf8).write(to: tmp.appendingPathComponent("config.json"))
        store.refreshStatus()
        #expect(store.status == .ready)
        #expect(store.activeLocation == .directory(tmp))
    }

    @Test
    func deleteRemovesMultiFileDirectory() throws {
        let tmp = makeTempDirectory()
        defer { cleanup(tmp) }
        let store = ParakeetModelStore(modelDirectory: tmp)
        try Data("weights".utf8).write(to: tmp.appendingPathComponent("model.safetensors"))
        try Data("{}".utf8).write(to: tmp.appendingPathComponent("config.json"))
        store.refreshStatus()
        #expect(store.status == .ready)

        try store.delete()

        #expect(store.status == .missing)
        #expect(!FileManager.default.fileExists(atPath: tmp.path))
    }

    @Test
    func cleanupReadyOnlyWhenAllRemoteFilesPresent() throws {
        let tmp = makeTempDirectory()
        defer { cleanup(tmp) }
        let store = CleanupModelStore(modelDirectory: tmp)
        #expect(store.status == .missing)

        let files = ModelDownloadSpec.gemmaCleanupE2B.remoteFiles
        // Write all but the last → still missing.
        for file in files.dropLast() {
            try Data("x".utf8).write(to: tmp.appendingPathComponent(file.destFilename))
        }
        store.refreshStatus()
        #expect(store.status == .missing)

        // Write the last → ready.
        try Data("x".utf8).write(to: tmp.appendingPathComponent(files.last!.destFilename))
        store.refreshStatus()
        #expect(store.status == .ready)
        #expect(store.activeLocation == .directory(tmp))
    }

    // MARK: - Directory composition from the spec subdirectory

    @Test
    func defaultModelDirectoryUsesSpecSubdirectory() {
        #expect(ParakeetModelStore().modelDirectory.path.hasSuffix("parakeet/tdt-0.6b-v2"))
        #expect(WhisperModelStore().modelDirectory.path.hasSuffix("whisper/small.en"))
        #expect(CleanupModelStore().modelDirectory.path.hasSuffix("llm/gemma-4-e2b-it-4bit"))
    }
}
