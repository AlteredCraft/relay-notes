import AVFoundation
import Foundation

struct RecordingOptions: Sendable {
    var format: AudioFormat = .m4aAAC
    var sessionMode: AVAudioSession.Mode = .measurement
    var bitrate: Int = 64_000
}

enum RecordingError: Error {
    case microphoneDenied
    case startFailed(any Error)
    case sessionConfigurationFailed(any Error)
    case audioFileCreationFailed(any Error)
}

enum InterruptionEvent: Sendable {
    case began      // the system took the audio session; capture is paused
    case resumed    // the session recovered; capture is live again
    case stopped    // the interruption ended without resuming; finalize what was captured
}

struct LiveRecording: Sendable {
    let url: URL
    let buffers: AsyncStream<AVAudioPCMBuffer>
    let interruptions: AsyncStream<InterruptionEvent>
}

@MainActor
final class LiveAudioEngine {
    private let engine = AVAudioEngine()
    private var tapState: TapState?
    private var currentURL: URL?
    private var interruptionContinuation: AsyncStream<InterruptionEvent>.Continuation?
    private var interruptionObserver: (any NSObjectProtocol)?

    func start(options: RecordingOptions, analyzerFormat: AVAudioFormat?) async throws -> LiveRecording {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { throw RecordingError.microphoneDenied }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: options.sessionMode, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            throw RecordingError.sessionConfigurationFailed(error)
        }

        let inputNode = engine.inputNode
        let tapFormat = inputNode.outputFormat(forBus: 0)

        let filename = "\(UUID().uuidString).\(options.format.fileExtension)"
        let url = URL.documentsDirectory.appending(path: filename)

        let audioFile: AVAudioFile
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: options.format.formatID,
                AVSampleRateKey: tapFormat.sampleRate,
                AVNumberOfChannelsKey: tapFormat.channelCount,
                AVEncoderBitRateKey: options.bitrate,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            audioFile = try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            throw RecordingError.audioFileCreationFailed(error)
        }

        let converter: AVAudioConverter?
        if let analyzerFormat, analyzerFormat != tapFormat {
            converter = AVAudioConverter(from: tapFormat, to: analyzerFormat)
        } else {
            converter = nil
        }

        let (buffers, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)

        let state = TapState(
            audioFile: audioFile,
            converter: converter,
            analyzerFormat: analyzerFormat,
            tapFormat: tapFormat,
            continuation: continuation
        )
        self.tapState = state
        self.currentURL = url

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [state] buffer, _ in
            state.handle(buffer: buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            continuation.finish()
            self.tapState = nil
            self.currentURL = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            throw RecordingError.startFailed(error)
        }

        let (interruptions, interruptionContinuation) = AsyncStream.makeStream(of: InterruptionEvent.self)
        self.interruptionContinuation = interruptionContinuation
        self.interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard
                let info = notification.userInfo,
                let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: rawType)
            else { return }
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            // `queue: .main` guarantees delivery on the main thread, i.e. the MainActor's executor.
            MainActor.assumeIsolated {
                self?.handleInterruption(type: type, shouldResume: shouldResume)
            }
        }

        return LiveRecording(url: url, buffers: buffers, interruptions: interruptions)
    }

    func stop() async -> URL? {
        // removeTap is a no-op when no tap is installed, so call it unconditionally — an
        // interruption-stopped engine reports `isRunning == false` but still holds the tap.
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil
        interruptionContinuation?.finish()
        interruptionContinuation = nil
        tapState?.finish()
        let url = currentURL
        tapState = nil
        currentURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return url
    }

    private func handleInterruption(type: AVAudioSession.InterruptionType, shouldResume: Bool) {
        switch type {
        case .began:
            // The system has already stopped the engine and deactivated our session. Nothing
            // is captured until the interruption ends; surface it so the UI can show "paused".
            interruptionContinuation?.yield(.began)
        case .ended:
            // Honor the system's resume hint. When set, reactivate and restart so capture
            // continues into the same file and transcription session (the tap is still
            // installed). Otherwise — or if restart fails — report stopped so the caller can
            // finalize what was already captured rather than lose the note.
            guard shouldResume else {
                interruptionContinuation?.yield(.stopped)
                return
            }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                try engine.start()
                interruptionContinuation?.yield(.resumed)
            } catch {
                interruptionContinuation?.yield(.stopped)
            }
        @unknown default:
            break
        }
    }
}

private final class TapState: @unchecked Sendable {
    private let audioFile: AVAudioFile
    private let converter: AVAudioConverter?
    private let analyzerFormat: AVAudioFormat?
    private let tapFormat: AVAudioFormat
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation

    init(
        audioFile: AVAudioFile,
        converter: AVAudioConverter?,
        analyzerFormat: AVAudioFormat?,
        tapFormat: AVAudioFormat,
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    ) {
        self.audioFile = audioFile
        self.converter = converter
        self.analyzerFormat = analyzerFormat
        self.tapFormat = tapFormat
        self.continuation = continuation
    }

    func handle(buffer: AVAudioPCMBuffer) {
        try? audioFile.write(from: buffer)

        guard let analyzerFormat else {
            continuation.yield(buffer)
            return
        }

        if let converter {
            let ratio = analyzerFormat.sampleRate / tapFormat.sampleRate
            // Slack on top of the resampled frame count so the converter never
            // runs short of output capacity on a fractional ratio / filter delay.
            let resamplerHeadroom: AVAudioFrameCount = 1024
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + resamplerHeadroom
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: outCapacity) else { return }

            var supplied = false
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if status != .error, error == nil, outBuffer.frameLength > 0 {
                continuation.yield(outBuffer)
            }
        } else {
            continuation.yield(buffer)
        }
    }

    func finish() {
        continuation.finish()
    }
}

private extension AVAudioApplication {
    static func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
