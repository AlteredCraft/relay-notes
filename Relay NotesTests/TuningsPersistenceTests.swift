import Foundation
import Testing
@testable import Relay_Notes

/// Round-trips the new T1.0 fields (`engine`, `whisperModelVariant`) through `UserDefaults` so
/// future cuts can rely on the persistence contract. Uses an isolated `UserDefaults` suite per test
/// to avoid contaminating `.standard` (which the app uses at runtime).
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

    @Test func whisperModelVariantDefaultsToSmallEN() {
        let defaults = makeDefaults()
        let tunings = Tunings(defaults: defaults)
        #expect(tunings.whisperModelVariant == .smallEN)
    }

    @Test func whisperModelVariantRoundTripsThroughUserDefaults() {
        let defaults = makeDefaults()
        let writer = Tunings(defaults: defaults)
        writer.whisperModelVariant = .tinyEN

        let reader = Tunings(defaults: defaults)
        #expect(reader.whisperModelVariant == .tinyEN)
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

    @Test func resetToDefaultsRestoresAppleAndSmallEN() {
        let defaults = makeDefaults()
        let tunings = Tunings(defaults: defaults)
        tunings.engine = .whisperMLX
        tunings.whisperModelVariant = .tinyEN

        tunings.resetToDefaults()

        #expect(tunings.engine == .apple)
        #expect(tunings.whisperModelVariant == .smallEN)
    }
}
