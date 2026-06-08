import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class RecorderViewModel {
    enum State: Equatable {
        case idle
        case recording(partial: String)
        case finalizing
        case finished(transcript: String)
        case failed(message: String)
    }

    private(set) var state: State = .idle

    let tunings: Tunings

    private let engine: LiveAudioEngine
    private let transcriber: any Transcriber
    private let modelContext: ModelContext

    private var session: (any TranscriptionSession)?
    private var feedTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var currentAudioURL: URL?

    init(
        engine: LiveAudioEngine,
        transcriber: any Transcriber,
        modelContext: ModelContext,
        tunings: Tunings
    ) {
        self.engine = engine
        self.transcriber = transcriber
        self.modelContext = modelContext
        self.tunings = tunings
    }

    func startRecording() async {
        do {
            let session = try await transcriber.makeStreamingSession(options: tunings.transcriptionOptions)
            self.session = session

            let recording = try await engine.start(
                options: tunings.recordingOptions,
                analyzerFormat: session.audioFormat
            )
            self.currentAudioURL = recording.url

            feedTask = Task { [session] in
                for await buffer in recording.buffers {
                    session.feed(buffer)
                }
            }

            updatesTask = Task { [weak self, session] in
                for await partial in session.updates {
                    guard let self else { return }
                    if case .recording = self.state {
                        self.state = .recording(partial: partial)
                    }
                }
            }

            state = .recording(partial: "")
        } catch RecordingError.microphoneDenied {
            await cleanupAfterFailure()
            state = .failed(message: "Microphone access is off. Enable it in Settings to record notes.")
        } catch TranscriptionError.notAuthorized {
            await cleanupAfterFailure()
            state = .failed(message: "Speech recognition isn't authorized. Enable it in Settings to transcribe.")
        } catch TranscriptionError.localeNotSupported {
            await cleanupAfterFailure()
            state = .failed(message: "Your current language isn't supported for on-device transcription.")
        } catch {
            await cleanupAfterFailure()
            state = .failed(message: "Couldn't start recording. Please try again.")
        }
    }

    func stopAndTranscribe() async {
        guard case .recording = state else { return }
        state = .finalizing

        let url = await engine.stop()
        feedTask?.cancel()
        feedTask = nil

        guard let session, let url else {
            updatesTask?.cancel()
            updatesTask = nil
            self.session = nil
            currentAudioURL = nil
            state = .failed(message: "Recording could not be saved. Please try again.")
            return
        }

        do {
            let transcript = try await session.finish()
            updatesTask?.cancel()
            updatesTask = nil
            self.session = nil
            currentAudioURL = nil

            let note = Note(audioFilename: url.lastPathComponent, transcript: transcript)
            modelContext.insert(note)
            try modelContext.save()
            state = .finished(transcript: transcript)
        } catch TranscriptionError.noSpeechDetected {
            await cleanupAfterFailure()
            try? FileManager.default.removeItem(at: url)
            state = .failed(message: "We didn't hear any speech. Try again and speak clearly.")
        } catch {
            await cleanupAfterFailure()
            try? FileManager.default.removeItem(at: url)
            state = .failed(message: "Something went wrong transcribing your note. Please try again.")
        }
    }

    func reset() {
        state = .idle
    }

    private func cleanupAfterFailure() async {
        feedTask?.cancel()
        feedTask = nil
        updatesTask?.cancel()
        updatesTask = nil
        if let session {
            await session.cancel()
        }
        session = nil
        currentAudioURL = nil
    }
}
