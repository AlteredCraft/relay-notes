import Foundation

/// Resolves the runtime `Transcriber` impl for a given `TranscriptionEngine`.
/// Instances are cached — load-bearing for Whisper, whose instance holds the
/// ~480 MB of model weights across calls (T1.2c).
@MainActor
final class TranscriberFactory {
    private let locale: Locale
    /// Handed to `WhisperMLXTranscriber` so it can prefer the downloaded
    /// model over the bundled one. `nil` (dev, tests) → bundled only.
    private let whisperModelStore: WhisperModelStore?
    private var appleSpeech: AppleSpeechTranscriber?
    private var whisperMLX: WhisperMLXTranscriber?

    init(locale: Locale = .current, whisperModelStore: WhisperModelStore? = nil) {
        self.locale = locale
        self.whisperModelStore = whisperModelStore
    }

    func transcriber(for engine: TranscriptionEngine) -> any Transcriber {
        switch engine {
        case .apple:
            if let appleSpeech { return appleSpeech }
            let new = AppleSpeechTranscriber(locale: locale)
            appleSpeech = new
            return new
        case .whisperMLX:
            if let whisperMLX { return whisperMLX }
            let new = WhisperMLXTranscriber(store: whisperModelStore)
            self.whisperMLX = new
            return new
        }
    }
}
