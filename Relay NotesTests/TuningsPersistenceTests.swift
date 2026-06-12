import Foundation
import Testing
@testable import Relay_Notes

/// Round-trips persisted `Tunings` fields through `UserDefaults` so future cuts can rely on the
/// persistence contract. Uses an isolated `UserDefaults` suite per test to avoid contaminating
/// `.standard` (which the app uses at runtime).
@MainActor
struct TuningsPersistenceTests {

    private func makeDefaults(_ id: String = UUID().uuidString) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "TuningsPersistenceTests.\(id)")!
        defaults.removePersistentDomain(forName: "TuningsPersistenceTests.\(id)")
        return defaults
    }

    @Test func engineDefaultsToApple() {
        let defaults = makeDefaults()
        let tunings = Tunings(defaults: defaults)
        #expect(tunings.engine == .apple)
    }

    @Test func engineRoundTripsThroughUserDefaults() {
        let defaults = makeDefaults()
        let writer = Tunings(defaults: defaults)
        writer.engine = .whisperMLX

        let reader = Tunings(defaults: defaults)
        #expect(reader.engine == .whisperMLX)
    }

    @Test func transcriptionOptionsMatchSelectedEngine() {
        let defaults = makeDefaults()
        let tunings = Tunings(defaults: defaults)

        tunings.engine = .apple
        if case .apple = tunings.transcriptionOptions {
        } else {
            Issue.record("Expected .apple options when engine is .apple")
        }

        tunings.engine = .whisperMLX
        if case .whisperMLX = tunings.transcriptionOptions {
        } else {
            Issue.record("Expected .whisperMLX options when engine is .whisperMLX")
        }
    }

    @Test func resetToDefaultsRestoresApple() {
        let defaults = makeDefaults()
        let tunings = Tunings(defaults: defaults)
        tunings.engine = .whisperMLX

        tunings.resetToDefaults()

        #expect(tunings.engine == .apple)
    }

    // MARK: - Engine ↔ model-presence invariant

    @Test func reconcileRevertsWhisperToAppleWhenModelMissing() {
        let tunings = Tunings(defaults: makeDefaults())
        tunings.engine = .whisperMLX

        tunings.reconcileEngineAvailability(whisperReady: false)

        #expect(tunings.engine == .apple)
    }

    @Test func reconcileKeepsWhisperWhenModelReady() {
        let tunings = Tunings(defaults: makeDefaults())
        tunings.engine = .whisperMLX

        tunings.reconcileEngineAvailability(whisperReady: true)

        #expect(tunings.engine == .whisperMLX)
    }

    @Test func reconcileLeavesAppleSelectionUntouched() {
        let tunings = Tunings(defaults: makeDefaults())
        tunings.engine = .apple

        tunings.reconcileEngineAvailability(whisperReady: false)

        #expect(tunings.engine == .apple)
    }
}
