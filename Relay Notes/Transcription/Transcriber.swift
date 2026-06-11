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

/// Both protocols below are `nonisolated` deliberately: they're isolation-neutral
/// by design — each conformer picks its own isolation (`AppleSpeechTranscriber`
/// is a nonisolated class, `WhisperMLXTranscriber` is an actor). Without the
/// annotation, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes an unannotated
/// protocol implicitly `@MainActor`, and conformance inference then propagates
/// `@MainActor` onto conformers — including onto an actor's synchronous `init`
/// (see CHANGE_LOG 2026-06-11). Protocols are *not* on SE-0466's exemption list;
/// declarations inside `actor` types are.
nonisolated protocol TranscriptionSession: Sendable, AnyObject {
    var audioFormat: AVAudioFormat? { get }
    var updates: AsyncStream<String> { get }
    func feed(_ buffer: AVAudioPCMBuffer)
    func finish() async throws -> String
    func cancel() async
}

nonisolated protocol Transcriber: Sendable {
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
