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

    @Test func sameEngineReturnsSameInstance() {
        let factory = TranscriberFactory()
        let first = factory.transcriber(for: .apple) as? AppleSpeechTranscriber
        let second = factory.transcriber(for: .apple) as? AppleSpeechTranscriber
        #expect(first != nil)
        #expect(first === second)
    }

    @Test func differentEnginesReturnDifferentInstances() {
        let factory = TranscriberFactory()
        let apple = factory.transcriber(for: .apple)
        let whisper = factory.transcriber(for: .whisperMLX)
        #expect(apple is AppleSpeechTranscriber)
        #expect(whisper is WhisperMLXTranscriber)
    }
}
