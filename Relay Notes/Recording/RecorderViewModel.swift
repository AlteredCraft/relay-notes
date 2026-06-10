import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class RecorderViewModel {
    enum State: Equatable {
        case idle
        case recording(partial: String)
        case paused(partial: String)
        case finalizing
        case finished(transcript: String)
        case failed(message: String)
    }

    private(set) var state: State = .idle

    let tunings: Tunings

    private let engine: LiveAudioEngine
    private let transcriberFactory: TranscriberFactory
    private let modelContext: ModelContext

    private var session: (any TranscriptionSession)?
    private var feedTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var interruptionTask: Task<Void, Never>?
    private var currentAudioURL: URL?

    init(
        engine: LiveAudioEngine,
        transcriberFactory: TranscriberFactory,
        modelContext: ModelContext,
        tunings: Tunings
    ) {
        self.engine = engine
        self.transcriberFactory = transcriberFactory
        self.modelContext = modelContext
        self.tunings = tunings
    }

    func startRecording() async {
        do {
            let transcriber = transcriberFactory.transcriber(for: tunings.engine)
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

            interruptionTask = Task { [weak self] in
                for await event in recording.interruptions {
                    guard let self else { return }
                    await self.handleInterruption(event)
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
        } catch let TranscriptionError.engineNotImplemented(message) {
            await cleanupAfterFailure()
            state = .failed(message: message)
        } catch {
            await cleanupAfterFailure()
            state = .failed(message: "Couldn't start recording. Please try again.")
        }
    }

    func stopAndTranscribe() async {
        switch state {
        case .recording, .paused: break
        default: return
        }
        state = .finalizing

        let url = await engine.stop()
        feedTask?.cancel()
        feedTask = nil
        interruptionTask?.cancel()
        interruptionTask = nil

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

    /// Pure mapping for the side-effect-free interruption transitions, factored out so it can be
    /// unit-tested without constructing the view model. Returns the next state, or `nil` when the
    /// event causes no direct state change (the caller may still run a side effect, e.g. finalizing
    /// on `.stopped`).
    static func nextState(for event: InterruptionEvent, from state: State) -> State? {
        switch (event, state) {
        case let (.began, .recording(partial)):
            return .paused(partial: partial)
        case let (.resumed, .paused(partial)):
            return .recording(partial: partial)
        default:
            return nil
        }
    }

    private func handleInterruption(_ event: InterruptionEvent) async {
        if let next = Self.nextState(for: event, from: state) {
            state = next
            return
        }
        // `.stopped` with no resume path: finalize so the captured audio isn't lost — there is no
        // manual "resume" affordance in the tap-to-record UI.
        if case .stopped = event, case .paused = state {
            await stopAndTranscribe()
        }
    }

    private func cleanupAfterFailure() async {
        feedTask?.cancel()
        feedTask = nil
        updatesTask?.cancel()
        updatesTask = nil
        interruptionTask?.cancel()
        interruptionTask = nil
        if let session {
            await session.cancel()
        }
        session = nil
        currentAudioURL = nil
    }
}
