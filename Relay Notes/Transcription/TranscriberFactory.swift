import Foundation

/// Resolves the runtime `Transcriber` impl for a given `TranscriptionEngine`.
/// Instances are cached, since both impls are cheap to construct today but
/// `WhisperMLXTranscriber` will hold model weights once T1.1 lands.
@MainActor
final class TranscriberFactory {
    private let locale: Locale
    private var appleSpeech: AppleSpeechTranscriber?
    private var whisperMLX: WhisperMLXTranscriber?

    init(locale: Locale = .current) {
        self.locale = locale
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
            let new = WhisperMLXTranscriber()
            self.whisperMLX = new
            return new
        }
    }
}
