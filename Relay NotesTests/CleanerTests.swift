import Foundation
import Testing
@testable import Relay_Notes

/// Records what it was asked to clean, so a test can assert `Cleaner` forwards the
/// right transcript + personalization without touching MLX. An `actor` — like the
/// real `MLXLanguageModel`, and the clean way to hold mutable recorded state behind
/// the `Sendable`, `nonisolated` `LanguageModel` protocol.
private actor RecordingLanguageModel: LanguageModel {
    private(set) var lastRaw: String?
    private(set) var lastPersonalization: CleanupPersonalization?
    private(set) var cleanCallCount = 0
    private(set) var evictCallCount = 0
    let cleanedToReturn = "CLEANED"

    func clean(_ raw: String, personalization: CleanupPersonalization) async throws -> String {
        lastRaw = raw
        lastPersonalization = personalization
        cleanCallCount += 1
        return cleanedToReturn
    }

    func evict() async { evictCallCount += 1 }
}

/// Sim-safe coverage for `Cleaner`'s gating, error mapping, and the
/// personalization-forwarding *wiring* (via an injected fake `LanguageModel`).
/// The actual generation stays device-only — validated via `LLMCleanupSmoke` /
/// in-app dogfooding, not here.
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

    // MARK: - Personalization forwarding (via injected fake model)

    /// Writes the model files into `dir` and flips the store to `.ready` — the
    /// precondition `Cleaner.clean` gates on.
    private func makeReadyStore(in dir: URL) throws -> CleanupModelStore {
        let store = CleanupModelStore(modelDirectory: dir)
        for file in ModelDownloadSpec.gemmaCleanupE2B.remoteFiles {
            try Data("x".utf8).write(to: dir.appendingPathComponent(file.destFilename))
        }
        store.refreshStatus()
        return store
    }

    @Test func cleanForwardsLivePersonalizationAndReusesModel() async throws {
        let tmp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try makeReadyStore(in: tmp)
        #expect(store.status == .ready)

        let fake = RecordingLanguageModel()
        var builds = 0
        // A mutable provider proves the personalization is read *live* per clean,
        // not snapshotted at Cleaner init.
        var current = CleanupPersonalization(domains: "iOS dev", terms: "")
        let cleaner = Cleaner(
            store: store,
            personalization: { current },
            makeModel: { builds += 1; return fake }
        )

        let outcome = try await cleaner.clean(Note(audioFilename: "a.m4a", transcript: "raw one"))
        #expect(await fake.cleanCallCount == 1)
        #expect(await fake.lastRaw == "raw one")
        #expect(await fake.lastPersonalization == CleanupPersonalization(domains: "iOS dev", terms: ""))
        #expect(outcome.cleaned == "CLEANED")
        #expect(outcome.modelLabel == Cleaner.modelLabel)

        // Edit personalization — the next clean must observe the NEW value.
        current = CleanupPersonalization(domains: "", terms: "MLX, Parakeet")
        _ = try await cleaner.clean(Note(audioFilename: "b.m4a", transcript: "raw two"))
        #expect(await fake.cleanCallCount == 2)
        #expect(await fake.lastRaw == "raw two")
        #expect(await fake.lastPersonalization == CleanupPersonalization(domains: "", terms: "MLX, Parakeet"))

        // Model built once and cached across cleans — not rebuilt each call.
        #expect(builds == 1)
    }

    @Test func defaultPersonalizationIsNone() async throws {
        let tmp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try makeReadyStore(in: tmp)

        let fake = RecordingLanguageModel()
        // No personalization provider passed → Cleaner defaults to `.none`.
        let cleaner = Cleaner(store: store, makeModel: { fake })

        _ = try await cleaner.clean(Note(audioFilename: "a.m4a", transcript: "x"))
        #expect(await fake.lastPersonalization == CleanupPersonalization.none)
    }

    @Test func cleanThrowsAndBuildsNoModelWhenStoreNotReady() async throws {
        // GH #13: `clean`'s own defensive re-check (model deleted between gate and
        // tap), distinct from the `isAvailable` gate. The guard returns before the
        // model is ever built — asserted via `builds == 0` on the injected factory.
        let tmp = makeTempDirectory()  // empty ⇒ store is .missing, not .ready
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = CleanupModelStore(modelDirectory: tmp)
        #expect(store.status != .ready)

        var builds = 0
        let cleaner = Cleaner(store: store, makeModel: { builds += 1; return RecordingLanguageModel() })

        await #expect(throws: LanguageModelError.self) {
            _ = try await cleaner.clean(Note(audioFilename: "a.m4a", transcript: "x"))
        }
        #expect(builds == 0)
    }

    @Test func evictReleasesModelAndNextCleanRebuilds() async throws {
        let tmp = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try makeReadyStore(in: tmp)

        let fake = RecordingLanguageModel()
        var builds = 0
        let cleaner = Cleaner(store: store, makeModel: { builds += 1; return fake })

        _ = try await cleaner.clean(Note(audioFilename: "a.m4a", transcript: "x"))
        #expect(builds == 1)

        await cleaner.evict()
        #expect(await fake.evictCallCount == 1)

        // Eviction cleared the cached model, so the next clean rebuilds via the factory.
        _ = try await cleaner.clean(Note(audioFilename: "b.m4a", transcript: "y"))
        #expect(builds == 2)
        #expect(await fake.cleanCallCount == 2)
    }
}
