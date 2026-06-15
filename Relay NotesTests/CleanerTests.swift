import Foundation
import Testing
@testable import Relay_Notes

/// Sim-safe coverage for `Cleaner`'s gating + error mapping (the parts that don't
/// touch MLX). The actual `clean(_:)` generation is device-only — validated via
/// `LLMCleanupSmoke` / in-app dogfooding, not here.
@MainActor
struct CleanerTests {

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanerTests.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func unavailableWhenModelMissing() {
        let tmp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cleaner = Cleaner(store: CleanupModelStore(modelDirectory: tmp))
        #expect(cleaner.isAvailable == false)
    }

    @Test func availableOnceAllModelFilesPresent() throws {
        let tmp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = CleanupModelStore(modelDirectory: tmp)
        for file in ModelDownloadSpec.gemmaCleanupE2B.remoteFiles {
            try Data("x".utf8).write(to: tmp.appendingPathComponent(file.destFilename))
        }
        store.refreshStatus()
        let cleaner = Cleaner(store: store)
        #expect(cleaner.isAvailable)
    }

    @Test func userMessageIsGenericAndActionable() {
        let msg = Cleaner.userMessage(for: LanguageModelError.modelUnavailable)
        #expect(msg == "Couldn't clean up this note. Please try again.")
    }

    @Test func modelLabelIsSet() {
        #expect(Cleaner.modelLabel == "Gemma 4 E2B (MLX 4-bit)")
    }
}
