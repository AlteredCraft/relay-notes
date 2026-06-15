import Foundation
import Speech
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

        tunings.engine = .parakeetMLX
        if case .parakeetMLX = tunings.transcriptionOptions {
        } else {
            Issue.record("Expected .parakeetMLX options when engine is .parakeetMLX")
        }
    }

    @Test func parakeetEngineRoundTripsThroughUserDefaults() {
        let defaults = makeDefaults()
        let writer = Tunings(defaults: defaults)
        writer.engine = .parakeetMLX

        let reader = Tunings(defaults: defaults)
        #expect(reader.engine == .parakeetMLX)
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

        // Whisper absent from the ready set (only Apple, which has no model).
        tunings.reconcileEngineAvailability(readyEngines: [.apple])

        #expect(tunings.engine == .apple)
    }

    @Test func reconcileKeepsWhisperWhenModelReady() {
        let tunings = Tunings(defaults: makeDefaults())
        tunings.engine = .whisperMLX

        tunings.reconcileEngineAvailability(readyEngines: [.apple, .whisperMLX])

        #expect(tunings.engine == .whisperMLX)
    }

    @Test func reconcileLeavesAppleSelectionUntouched() {
        let tunings = Tunings(defaults: makeDefaults())
        tunings.engine = .apple

        tunings.reconcileEngineAvailability(readyEngines: [.apple])

        #expect(tunings.engine == .apple)
    }

    // MARK: - Per-engine bundles (Approach C)

    @Test func appleBundleDefaultsWhenUnset() {
        let tunings = Tunings(defaults: makeDefaults())
        #expect(tunings.apple == AppleSpeechSettings())
        #expect(tunings.apple.preset == .transcription)
        #expect(tunings.apple.contextualStringsText.isEmpty)
    }

    @Test func appleBundleRoundTripsThroughLegacyKeys() {
        // Persistence must reuse the original flat keys so existing installs
        // keep their settings — no migration. This pins both the round-trip and
        // the literal key names the no-migration promise depends on.
        let defaults = makeDefaults()
        let writer = Tunings(defaults: defaults)
        writer.apple.preset = .progressiveTranscription
        writer.apple.contextualStringsText = "MLX, Qwen"

        #expect(defaults.string(forKey: "tunings.contextualStringsText") == "MLX, Qwen")
        #expect(defaults.string(forKey: "tunings.preset") == "progressive")

        let reader = Tunings(defaults: defaults)
        #expect(reader.apple.preset == .progressiveTranscription)
        #expect(reader.apple.contextualStringsText == "MLX, Qwen")
    }

    @Test func switchingEnginePreservesAppleBundle() {
        // Hiding Apple's dials under Whisper must not clear them — they reappear
        // on switch-back. The bundle lives independent of `engine`.
        let tunings = Tunings(defaults: makeDefaults())
        tunings.apple.preset = .transcriptionWithAlternatives
        tunings.apple.contextualStringsText = "AlteredCraft"

        tunings.engine = .whisperMLX
        tunings.engine = .apple

        #expect(tunings.apple.preset == .transcriptionWithAlternatives)
        #expect(tunings.apple.contextualStringsText == "AlteredCraft")
    }

    @Test func transcriptionOptionsCarryAppleBundle() {
        let tunings = Tunings(defaults: makeDefaults())
        tunings.engine = .apple
        tunings.apple.preset = .transcriptionWithAlternatives
        tunings.apple.contextualStringsText = "a, b ,,c"

        guard case let .apple(options) = tunings.transcriptionOptions else {
            Issue.record("Expected .apple options when engine is .apple")
            return
        }
        #expect(options.preset == .transcriptionWithAlternatives)
        #expect(options.contextualStrings == ["a", "b", "c"])  // trimmed, empties dropped
    }

    @Test func whisperEngineIgnoresAppleBundle() {
        // Even with Apple dials set, selecting Whisper yields bare `.whisperMLX`
        // — the dials are inert, which is exactly why they're hidden in the UI.
        let tunings = Tunings(defaults: makeDefaults())
        tunings.apple.preset = .progressiveTranscription
        tunings.apple.contextualStringsText = "ignored"
        tunings.engine = .whisperMLX

        guard case .whisperMLX = tunings.transcriptionOptions else {
            Issue.record("Expected .whisperMLX options when engine is .whisperMLX")
            return
        }
    }

    @Test func resetToDefaultsClearsBundles() {
        let tunings = Tunings(defaults: makeDefaults())
        tunings.apple.preset = .progressiveTranscription
        tunings.apple.contextualStringsText = "MLX"
        tunings.engine = .whisperMLX

        tunings.resetToDefaults()

        #expect(tunings.apple == AppleSpeechSettings())
        #expect(tunings.whisper == WhisperSettings())
        #expect(tunings.parakeet == ParakeetSettings())
        #expect(tunings.engine == .apple)
    }
}
