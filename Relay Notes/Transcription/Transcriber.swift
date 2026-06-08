import Foundation
import Speech

struct TranscriptionOptions: Sendable {
    var preset: SpeechTranscriber.Preset = .transcription
    var contextualStrings: [String] = []
}

protocol Transcriber: Sendable {
    func transcribe(_ audio: URL, options: TranscriptionOptions) async throws -> String
}

enum TranscriptionError: Error {
    case notAuthorized
    case localeNotSupported(Locale)
    case assetInstallationFailed(any Error)
    case audioOpenFailed(any Error)
    case noSpeechDetected
    case underlying(any Error)
}
