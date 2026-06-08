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
    }

    var sessionMode: AVAudioSession.Mode {
        didSet { UserDefaults.standard.set(sessionMode.rawValue, forKey: Key.sessionMode) }
    }

    var bitrate: Int {
        didSet { UserDefaults.standard.set(bitrate, forKey: Key.bitrate) }
    }

    var preset: SpeechTranscriber.Preset {
        didSet { UserDefaults.standard.set(Self.presetID(preset), forKey: Key.preset) }
    }

    var contextualStringsText: String {
        didSet { UserDefaults.standard.set(contextualStringsText, forKey: Key.contextualStringsText) }
    }

    init() {
        let defaults = UserDefaults.standard

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
    }

    func resetToDefaults() {
        sessionMode = .default
        bitrate = 64_000
        preset = .transcription
        contextualStringsText = ""
    }

    var recordingOptions: RecordingOptions {
        RecordingOptions(
            format: .m4aAAC,
            sessionMode: sessionMode,
            bitrate: bitrate
        )
    }

    var transcriptionOptions: TranscriptionOptions {
        let strings = contextualStringsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return TranscriptionOptions(preset: preset, contextualStrings: strings)
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
