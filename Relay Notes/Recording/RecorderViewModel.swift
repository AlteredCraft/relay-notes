import AVFoundation
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

    /// Whether the active recording's engine streams live partials. Captured
    /// from the session at record start (the session is the authority). Drives
    /// `RecorderView`'s choice between the live transcript card and the Whisper
    /// placeholder card, and persists through `.finalizing` so the spinner can
    /// read "Transcribing…" vs "Finalizing…". Defaults `true` so nothing shows
    /// a placeholder before a recording starts.
    private(set) var emitsLivePartials = true

    /// Normalized 0...1 mic level, updated from the feed loop while a
    /// non-streaming engine records — the placeholder's "you're being heard"
    /// feedback in lieu of a live transcript. Stays 0 for streaming engines.
    private(set) var audioLevel: Float = 0

    /// Wall-clock recording time, accumulated only while `.recording` (frozen
    /// during interruption pauses). Shown in the Whisper placeholder.
    private(set) var elapsed: Duration = .zero

    let tunings: Tunings

    private let engine: LiveAudioEngine
    private let transcriberFactory: TranscriberFactory
    private let modelContext: ModelContext

    private var session: (any TranscriptionSession)?
    private var feedTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var interruptionTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
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
            self.emitsLivePartials = session.emitsLivePartials
            self.audioLevel = 0
            self.elapsed = .zero

            let recording = try await engine.start(
                options: tunings.recordingOptions,
                analyzerFormat: session.audioFormat
            )
            self.currentAudioURL = recording.url

            feedTask = Task { [weak self, session] in
                for await buffer in recording.buffers {
                    session.feed(buffer)
                    self?.updateAudioLevel(from: buffer)
                }
            }

            // Only non-streaming engines (Whisper) show the placeholder's meter
            // + elapsed label; for Apple Speech the live partial card carries
            // the feedback, so leave that path untouched (no ticker, no level).
            if !session.emitsLivePartials {
                startElapsedTicker()
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
        elapsedTask?.cancel()
        elapsedTask = nil

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

            let note = Note(
                audioFilename: url.lastPathComponent,
                transcript: transcript,
                transcriptionModel: session.modelDescription
            )
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

    /// Accumulates `elapsed` from real clock deltas, adding time only while the
    /// state is `.recording`. Banking actual deltas (rather than a fixed
    /// per-tick increment) keeps the label drift-free; gating on `.recording`
    /// freezes it during interruption pauses without any transition wiring.
    private func startElapsedTicker() {
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                let now = clock.now
                let delta = now - last
                last = now
                if case .recording = self.state {
                    self.elapsed += delta
                }
            }
        }
    }

    /// Computes a smoothed mic level from a fed PCM buffer for the placeholder
    /// meter. No-op for streaming engines — their live card is the feedback, so
    /// we skip the per-buffer work and the `@Observable` churn entirely.
    private func updateAudioLevel(from buffer: AVAudioPCMBuffer) {
        guard !emitsLivePartials, let channel = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        let samples = channel[0]
        var sumSquares: Float = 0
        for i in 0..<count {
            let sample = samples[i]
            sumSquares += sample * sample
        }
        let rms = (sumSquares / Float(count)).squareRoot()
        let target = Self.normalizedLevel(rms: rms)
        // Fast attack, slow decay — the meter jumps to peaks but eases back, so
        // it reads as a level rather than a flicker.
        audioLevel = target >= audioLevel ? target : audioLevel * 0.75 + target * 0.25
    }

    /// Maps an RMS amplitude (0...1) to a 0...1 meter value on a dB scale with a
    /// −50 dB noise floor — linear amplitude crushes speech into the bottom few
    /// percent, so the meter would barely move. Pure + `nonisolated` for tests.
    nonisolated static func normalizedLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        let floor: Float = -50
        if db <= floor { return 0 }
        if db >= 0 { return 1 }
        return (db - floor) / -floor
    }

    /// Formats a recording duration as `M:SS`. Pure + `nonisolated` for tests.
    nonisolated static func formatElapsed(_ duration: Duration) -> String {
        let totalSeconds = max(0, Int(duration.components.seconds))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func cleanupAfterFailure() async {
        feedTask?.cancel()
        feedTask = nil
        updatesTask?.cancel()
        updatesTask = nil
        interruptionTask?.cancel()
        interruptionTask = nil
        elapsedTask?.cancel()
        elapsedTask = nil
        if let session {
            await session.cancel()
        }
        session = nil
        currentAudioURL = nil
    }
}
