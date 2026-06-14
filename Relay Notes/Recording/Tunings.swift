import AVFoundation
import Foundation
import Observation
import Speech

/// Per-engine recognition settings, separated from `Tunings` so the model
/// mirrors the `TranscriptionOptions` tagged union (one bundle per engine).
/// Adding an engine adds a bundle here, not another flat field on `Tunings`.
///
/// These hold the *editable / persisted* representation (e.g. raw comma text);
/// `Tunings.transcriptionOptions` converts them to the domain `…Options` values
/// (e.g. parsed `[String]`) that cross the `Transcriber` boundary.
struct AppleSpeechSettings: Sendable, Equatable {
    var preset: SpeechTranscriber.Preset = .transcription
    var contextualStringsText: String = ""
}

/// Reserved home for on-device Whisper decode dials. Empty in v1 — Whisper
/// exposes no user-facing decode settings yet (temperature, `no_speech`
/// thresholds, `condition_on_previous_text`, and `initial_prompt` biasing are
/// fixed or deliberately unported; see `planning/transcription-tuning.md`).
/// Exists so the engine-specific surface is symmetric and future dials have a
/// place to land.
struct WhisperSettings: Sendable, Equatable {}

@MainActor
@Observable
final class Tunings {
    private enum Key {
        static let sessionMode = "tunings.sessionMode"
        static let bitrate = "tunings.bitrate"
        static let preset = "tunings.preset"
        static let contextualStringsText = "tunings.contextualStringsText"
        static let engine = "tunings.engine"
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    // MARK: Shared — capture

    var sessionMode: AVAudioSession.Mode {
        didSet { defaults.set(sessionMode.rawValue, forKey: Key.sessionMode) }
    }

    // MARK: Shared — storage / playback

    var bitrate: Int {
        didSet { defaults.set(bitrate, forKey: Key.bitrate) }
    }

    // MARK: Shared — engine selector

    var engine: TranscriptionEngine {
        didSet { defaults.set(engine.rawValue, forKey: Key.engine) }
    }

    // MARK: Per-engine bundles
    //
    // Persistence intentionally reuses the original flat keys (`tunings.preset`,
    // `tunings.contextualStringsText`) so existing installs keep their settings
    // with no migration — only the in-memory shape changed. Mutating a field of
    // a struct held in a `var` runs the property's setter, so these `didSet`s
    // fire on `$tunings.apple.preset`-style binding edits from Settings.

    var apple: AppleSpeechSettings {
        didSet {
            defaults.set(Self.presetID(apple.preset), forKey: Key.preset)
            defaults.set(apple.contextualStringsText, forKey: Key.contextualStringsText)
        }
    }

    /// No persisted fields yet — reserved (see `WhisperSettings`).
    var whisper: WhisperSettings

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Shared
        if let modeRaw = defaults.string(forKey: Key.sessionMode) {
            self.sessionMode = AVAudioSession.Mode(rawValue: modeRaw)
        } else {
            self.sessionMode = .default
        }

        let storedBitrate = defaults.integer(forKey: Key.bitrate)
        self.bitrate = storedBitrate > 0 ? storedBitrate : 64_000

        if let engineRaw = defaults.string(forKey: Key.engine),
           let restored = TranscriptionEngine(rawValue: engineRaw) {
            self.engine = restored
        } else {
            self.engine = .apple
        }

        // Apple bundle — restored from the same legacy keys.
        let restoredPreset: SpeechTranscriber.Preset
        if let presetID = defaults.string(forKey: Key.preset),
           let restored = Self.presetFromID(presetID) {
            restoredPreset = restored
        } else {
            restoredPreset = .transcription
        }
        self.apple = AppleSpeechSettings(
            preset: restoredPreset,
            contextualStringsText: defaults.string(forKey: Key.contextualStringsText) ?? ""
        )

        // Whisper bundle — nothing persisted yet.
        self.whisper = WhisperSettings()
    }

    func resetToDefaults() {
        sessionMode = .default
        bitrate = 64_000
        engine = .apple
        apple = AppleSpeechSettings()
        whisper = WhisperSettings()
    }

    /// Enforces the invariant that a model-backed engine can only be the selected
    /// engine while its model is present on disk. If the selected engine isn't in
    /// `readyEngines`, fall back to Apple (which has no model and is always ready,
    /// so it's always present in the set). Single source of truth for the rule —
    /// called at launch (a persisted engine choice can outlive a deleted model)
    /// and right after a model delete.
    ///
    /// Per-engine since T2.3: `readyEngines` comes from `ModelStores.readyEngines`,
    /// so adding an on-device engine needs no change here — the new engine is
    /// simply absent from the set until its model downloads.
    func reconcileEngineAvailability(readyEngines: Set<TranscriptionEngine>) {
        if !readyEngines.contains(engine) {
            engine = .apple
        }
    }

    var recordingOptions: RecordingOptions {
        RecordingOptions(
            format: .m4aAAC,
            sessionMode: sessionMode,
            bitrate: bitrate
        )
    }

    var transcriptionOptions: TranscriptionOptions {
        switch engine {
        case .apple:
            let strings = apple.contextualStringsText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return .apple(AppleSpeechOptions(preset: apple.preset, contextualStrings: strings))
        case .whisperMLX:
            return .whisperMLX
        }
    }

    private static func presetID(_ preset: SpeechTranscriber.Preset) -> String {
        if preset == .transcription { return "transcription" }
        if preset == .transcriptionWithAlternatives { return "withAlternatives" }
        if preset == .progressiveTranscription { return "progressive" }
        return "transcription"
    }

    private static func presetFromID(_ id: String) -> SpeechTranscriber.Preset? {
        switch id {
        case "transcription": return .transcription
        case "withAlternatives": return .transcriptionWithAlternatives
        case "progressive": return .progressiveTranscription
        default: return nil
        }
    }
}
