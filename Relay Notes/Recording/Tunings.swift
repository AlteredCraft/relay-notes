import AVFoundation
import Foundation
import Observation
import Speech

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

    var sessionMode: AVAudioSession.Mode {
        didSet { defaults.set(sessionMode.rawValue, forKey: Key.sessionMode) }
    }

    var bitrate: Int {
        didSet { defaults.set(bitrate, forKey: Key.bitrate) }
    }

    var preset: SpeechTranscriber.Preset {
        didSet { defaults.set(Self.presetID(preset), forKey: Key.preset) }
    }

    var contextualStringsText: String {
        didSet { defaults.set(contextualStringsText, forKey: Key.contextualStringsText) }
    }

    var engine: TranscriptionEngine {
        didSet { defaults.set(engine.rawValue, forKey: Key.engine) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let modeRaw = defaults.string(forKey: Key.sessionMode) {
            self.sessionMode = AVAudioSession.Mode(rawValue: modeRaw)
        } else {
            self.sessionMode = .default
        }

        let storedBitrate = defaults.integer(forKey: Key.bitrate)
        self.bitrate = storedBitrate > 0 ? storedBitrate : 64_000

        if let presetID = defaults.string(forKey: Key.preset),
           let restored = Self.presetFromID(presetID) {
            self.preset = restored
        } else {
            self.preset = .transcription
        }

        self.contextualStringsText = defaults.string(forKey: Key.contextualStringsText) ?? ""

        if let engineRaw = defaults.string(forKey: Key.engine),
           let restored = TranscriptionEngine(rawValue: engineRaw) {
            self.engine = restored
        } else {
            self.engine = .apple
        }
    }

    func resetToDefaults() {
        sessionMode = .default
        bitrate = 64_000
        preset = .transcription
        contextualStringsText = ""
        engine = .apple
    }

    /// Enforces the invariant that Whisper can only be the selected engine
    /// while its model is present on disk. If Whisper is selected but the model
    /// isn't ready, fall back to Apple (always available). Single source of
    /// truth for the rule — called at launch (a persisted `.whisperMLX` choice
    /// can outlive a deleted model) and right after a model delete. No-op when
    /// Apple is selected or the model is ready.
    func reconcileEngineAvailability(whisperReady: Bool) {
        if engine == .whisperMLX && !whisperReady {
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
            let strings = contextualStringsText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return .apple(AppleSpeechOptions(preset: preset, contextualStrings: strings))
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
