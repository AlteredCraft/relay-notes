import AVFoundation
import Foundation
import Speech

enum TranscriptionOptions: Sendable {
    case apple(AppleSpeechOptions)
    case whisperMLX
    case parakeetMLX
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
    /// Whether this session streams incremental partials through `updates`
    /// while recording. The session is the authority — it knows its own decode
    /// model — so the recorder asks it rather than inferring from the engine
    /// enum. `false` (e.g. Whisper, which accumulates and decodes once at
    /// `finish()`) tells `RecorderView` to show a placeholder instead of a
    /// perpetually blank live transcript card (T1.2f).
    var emitsLivePartials: Bool { get }
    /// Human-readable label of the engine/model producing this transcript,
    /// persisted on the `Note` for provenance (e.g. "Apple Speech",
    /// "Whisper (small.en)"). The session is the authority — it knows which
    /// model it loaded — so it reports its own identity rather than the caller
    /// inferring it from the engine enum.
    var modelDescription: String { get }
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
    /// A model-backed engine was asked to transcribe but its weights aren't on
    /// disk (no store injected, or the model was deleted). The app gates engine
    /// selection on model presence, so this is defensive — it maps to the
    /// recorder's generic "something went wrong" message, never a raw detail.
    case modelUnavailable
    case underlying(any Error)
}
