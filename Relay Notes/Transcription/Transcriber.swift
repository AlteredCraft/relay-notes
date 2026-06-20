import AVFoundation
import Foundation
import Speech

/// Per-engine transcription configuration, passed into `Transcriber`. Only Apple
/// Speech carries tunable options today; the MLX engines run fixed pipelines.
enum TranscriptionOptions: Sendable {
    case apple(AppleSpeechOptions)
    case whisperMLX
    case parakeetMLX
}

/// Apple Speech dials: the recognition `preset` and any `contextualStrings`
/// (domain terms/names biased toward during recognition). Defaults are set in
/// `Tunings`; what each does is in `planning/transcription-tuning.md`.
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
/// A live transcription session: the recorder feeds it captured audio buffers and
/// reads back partials, then `finish()`es it for the final transcript. One
/// session per recording; conformers pick their own isolation (hence
/// `nonisolated`, see below).
nonisolated protocol TranscriptionSession: Sendable, AnyObject {
    /// The PCM format this session wants buffers in; the capture engine converts
    /// to it before `feed(_:)`. `nil` means "no preference" (use the tap format).
    var audioFormat: AVAudioFormat? { get }
    /// Incremental transcript stream while recording (see `emitsLivePartials`).
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
    /// Hand one captured audio buffer to the session (called from the audio feed).
    func feed(_ buffer: AVAudioPCMBuffer)
    /// Close input and return the final transcript. Throws
    /// `TranscriptionError.noSpeechDetected` when nothing was recognized.
    func finish() async throws -> String
    /// Abandon the session and release its resources without producing a result.
    func cancel() async
}

/// A transcription engine, hidden behind a protocol so the runtime provider is
/// swappable (the architecture spine — see CLAUDE.md). Conformers choose their own
/// isolation, so this is `nonisolated`. Both methods are intentional: the
/// streaming one is what the recorder uses today; the file-based one is currently
/// unused but reserved for cloud STT and a future "re-transcribe" action — **do
/// not remove it as dead code.**
nonisolated protocol Transcriber: Sendable {
    /// Transcribe an already-recorded audio file in one shot. Reserved (cloud STT,
    /// re-transcribe); not on the live recording path today.
    func transcribe(_ audio: URL, options: TranscriptionOptions) async throws -> String
    /// Open a streaming session fed live audio buffers — the recorder's path.
    func makeStreamingSession(options: TranscriptionOptions) async throws -> any TranscriptionSession
}

/// Failures surfaced by the transcription layer. The recorder maps each to a
/// generic, actionable user message; the specific case stays in logs.
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
