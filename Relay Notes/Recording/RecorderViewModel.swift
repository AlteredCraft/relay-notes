import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class RecorderViewModel {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case finished(transcript: String)
        case failed(message: String)
    }

    private(set) var state: State = .idle

    let tunings: Tunings

    private let recorder: any AudioRecording
    private let transcriber: any Transcriber
    private let modelContext: ModelContext

    init(
        recorder: any AudioRecording,
        transcriber: any Transcriber,
        modelContext: ModelContext,
        tunings: Tunings
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.modelContext = modelContext
        self.tunings = tunings
    }

    func startRecording() async {
        do {
            _ = try await recorder.startRecording(options: tunings.recordingOptions)
            state = .recording
        } catch RecordingError.microphoneDenied {
            state = .failed(message: "Microphone access is off. Enable it in Settings to record notes.")
        } catch {
            state = .failed(message: "Couldn't start recording. Please try again.")
        }
    }

    func stopAndTranscribe() async {
        guard state == .recording else { return }
        guard let audioURL = await recorder.stopRecording() else {
            state = .failed(message: "Recording could not be saved. Please try again.")
            return
        }

        state = .transcribing
        do {
            let transcript = try await transcriber.transcribe(audioURL, options: tunings.transcriptionOptions)
            let note = Note(audioFilename: audioURL.lastPathComponent, transcript: transcript)
            modelContext.insert(note)
            try modelContext.save()
            state = .finished(transcript: transcript)
        } catch TranscriptionError.notAuthorized {
            state = .failed(message: "Speech recognition isn't authorized. Enable it in Settings to transcribe.")
        } catch TranscriptionError.noSpeechDetected {
            state = .failed(message: "We didn't hear any speech. Try again and speak clearly.")
        } catch TranscriptionError.localeNotSupported {
            state = .failed(message: "Your current language isn't supported for on-device transcription.")
        } catch {
            state = .failed(message: "Something went wrong transcribing your note. Please try again.")
        }
    }

    func reset() {
        state = .idle
    }
}
