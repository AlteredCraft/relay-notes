import Testing
@testable import Relay_Notes

/// Verifies `TranscriberFactory` resolves engine → impl correctly and caches instances per engine.
/// Caching matters once `WhisperMLXTranscriber` holds model weights (T1.1+); proving it here means
/// the contract is locked before that lands.
@MainActor
struct TranscriberFactoryTests {

    @Test func appleEngineReturnsAppleSpeechTranscriber() {
        let factory = TranscriberFactory()
        let transcriber = factory.transcriber(for: .apple)
        #expect(transcriber is AppleSpeechTranscriber)
    }

    @Test func whisperMLXEngineReturnsWhisperMLXTranscriber() {
        let factory = TranscriberFactory()
        let transcriber = factory.transcriber(for: .whisperMLX)
        #expect(transcriber is WhisperMLXTranscriber)
    }

    @Test func parakeetMLXEngineReturnsParakeetMLXTranscriber() {
        let factory = TranscriberFactory()
        let transcriber = factory.transcriber(for: .parakeetMLX)
        #expect(transcriber is ParakeetMLXTranscriber)
    }

    @Test func sameEngineReturnsSameInstance() {
        let factory = TranscriberFactory()
        let first = factory.transcriber(for: .apple) as? AppleSpeechTranscriber
        let second = factory.transcriber(for: .apple) as? AppleSpeechTranscriber
        #expect(first != nil)
        #expect(first === second)
    }

    /// The single-live-MLX cache (T2.4): re-requesting the same MLX engine returns
    /// the cached instance, so its loaded weights aren't reloaded.
    @Test func sameMLXEngineReturnsSameInstance() {
        let factory = TranscriberFactory()
        let first = factory.transcriber(for: .whisperMLX) as? WhisperMLXTranscriber
        let second = factory.transcriber(for: .whisperMLX) as? WhisperMLXTranscriber
        #expect(first != nil)
        #expect(first === second)
    }

    /// Toggling Apple↔an MLX engine doesn't evict the cached MLX transcriber
    /// (Apple isn't MLX-backed) — the same Whisper instance survives a detour
    /// through Apple, so its weights stay resident.
    @Test func mlxInstanceSurvivesAppleDetour() {
        let factory = TranscriberFactory()
        let whisper1 = factory.transcriber(for: .whisperMLX) as? WhisperMLXTranscriber
        _ = factory.transcriber(for: .apple)
        let whisper2 = factory.transcriber(for: .whisperMLX) as? WhisperMLXTranscriber
        #expect(whisper1 != nil)
        #expect(whisper1 === whisper2)
    }

    @Test func differentEnginesReturnDifferentInstances() {
        let factory = TranscriberFactory()
        let apple = factory.transcriber(for: .apple)
        let whisper = factory.transcriber(for: .whisperMLX)
        #expect(apple is AppleSpeechTranscriber)
        #expect(whisper is WhisperMLXTranscriber)
    }

    /// The single-live-MLX eviction (T2.4): switching to the *other* MLX engine
    /// drops the prior one's cached instance, so coming back rebuilds it (a fresh
    /// object) rather than reusing the evicted one — proving Whisper and Parakeet
    /// are never co-resident.
    @Test func switchingMLXEnginesEvictsPrevious() {
        let factory = TranscriberFactory()
        let whisper1 = factory.transcriber(for: .whisperMLX) as? WhisperMLXTranscriber
        _ = factory.transcriber(for: .parakeetMLX)  // evicts whisper1
        let whisper2 = factory.transcriber(for: .whisperMLX) as? WhisperMLXTranscriber  // rebuilt
        #expect(whisper1 != nil)
        #expect(whisper2 != nil)
        #expect(whisper1 !== whisper2)
    }
}
