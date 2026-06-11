import AVFoundation
import Foundation
import Speech

enum TranscriptionOptions: Sendable {
    case apple(AppleSpeechOptions)
    case whisperMLX
}

struct AppleSpeechOptions: Sendable {
    var preset: SpeechTranscriber.Preset = .transcription
    var contextualStrings: [String] = []
}

protocol TranscriptionSession: Sendable, AnyObject {
    var audioFormat: AVAudioFormat? { get }
    var updates: AsyncStream<String> { get }
    func feed(_ buffer: AVAudioPCMBuffer)
    func finish() async throws -> String
    func cancel() async
}

protocol Transcriber: Sendable {
    func transcribe(_ audio: URL, options: TranscriptionOptions) async throws -> String
    func makeStreamingSession(options: TranscriptionOptions) async throws -> any TranscriptionSession
}

enum TranscriptionError: Error {
    case notAuthorized
    case localeNotSupported(Locale)
    case assetInstallationFailed(any Error)
    case audioOpenFailed(any Error)
    case noSpeechDetected
    case engineNotImplemented(String)
    case underlying(any Error)
}
