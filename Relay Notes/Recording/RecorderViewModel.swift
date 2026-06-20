import AVFoundation
import Foundation
import Observation
import SwiftData

/// Drives the tap-to-record flow: owns the capture engine + streaming
/// transcription session, advances the recording state machine, and persists the
/// finished `Note`. Constructed lazily in `ContentView.task` and read by
/// `RecorderView`.
@MainActor
@Observable
final class RecorderViewModel {
    /// The recording state machine. `partial` carries the latest streamed
    /// transcript through `.recording`/`.paused` (empty for non-streaming
    /// engines); `.paused` is driven by `AVAudioSession` interruptions, not the
    /// user. See the "Tap-to-record state machine" note in CLAUDE.md.
    enum State: Equatable {
        case idle
        case recording(partial: String)
        case paused(partial: String)
        case finalizing
        case finished(transcript: String)
        case failed(message: String)
    }

    /// Current point in the recording flow; the single source of truth `RecorderView` renders.
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

    /// Live recording/transcription dials, also surfaced to `SettingsView`. A
    /// snapshot is read at record start, so mid-recording edits don't take effect
    /// until the next session (see `Tunings`).
    let tunings: Tunings

    private let engine: LiveAudioEngine
    private let transcriberFactory: TranscriberFactory
    private let modelContext: ModelContext

    /// The active streaming session, set at record start and released at finalize.
    private var session: (any TranscriptionSession)?
    /// Forwards captured audio buffers to the session (and drives the meter).
    private var feedTask: Task<Void, Never>?
    /// Mirrors the session's partial-transcript stream into `state`.
    private var updatesTask: Task<Void, Never>?
    /// Relays `AVAudioSession` interruption events into the state machine.
    private var interruptionTask: Task<Void, Never>?
    /// Accumulates `elapsed` for the non-streaming placeholder; nil otherwise.
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

    /// Starts a streaming session and audio capture, wiring the feed, partials,
    /// interruption, and (for non-streaming engines) elapsed-ticker tasks, then
    /// enters `.recording`. Any failure tears everything down and lands in
    /// `.failed` with a generic, actionable message (specifics stay in logs).
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

    /// Stops capture, finalizes the session into a transcript, and persists a
    /// `Note` (audio + transcript + model provenance). No-op unless currently
    /// `.recording`/`.paused`. On a missing recording or a finalize/empty-speech
    /// failure, deletes the orphaned audio and lands in `.failed`.
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

        // Light teardown shared by both the guard-else failure and the success
        // paths: cancel the partials loop and release the stored session up-front,
        // finishing on a local handle. State is already `.finalizing`, so the
        // partials loop is a no-op from here — cancelling it early changes nothing.
        // (The catch paths still need this `session` to `cancel()` it, hence the
        // local; they don't route through `cleanupAfterFailure()`, whose remaining
        // work is already done here.)
        updatesTask?.cancel()
        updatesTask = nil
        let session = self.session
        self.session = nil
        currentAudioURL = nil

        guard let session, let url else {
            state = .failed(message: "Recording could not be saved. Please try again.")
            return
        }

        do {
            let transcript = try await session.finish()
            let note = Note(
                audioFilename: url.lastPathComponent,
                transcript: transcript,
                transcriptionModel: session.modelDescription
            )
            modelContext.insert(note)
            try modelContext.save()
            state = .finished(transcript: transcript)
        } catch TranscriptionError.noSpeechDetected {
            await session.cancel()
            try? FileManager.default.removeItem(at: url)
            state = .failed(message: "We didn't hear any speech. Try again and speak clearly.")
        } catch {
            await session.cancel()
            try? FileManager.default.removeItem(at: url)
            state = .failed(message: "Something went wrong transcribing your note. Please try again.")
        }
    }

    /// Returns to `.idle` after the user dismisses a `.finished`/`.failed` result,
    /// readying the recorder for the next take.
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

    /// Applies an `AVAudioSession` interruption: pure pause/resume transitions via
    /// `nextState`, or — on `.stopped` while paused — auto-finalizes so the
    /// captured audio isn't lost (there's no manual-resume affordance).
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

    /// Heavy teardown for the failure paths: cancels every task and `cancel()`s
    /// the session (vs. the lighter inline teardown in `stopAndTranscribe()`'s
    /// success path, which `finish()`es the session instead).
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
