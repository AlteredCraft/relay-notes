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

struct LiveRecording: Sendable {
    let url: URL
    let buffers: AsyncStream<AVAudioPCMBuffer>
}

@MainActor
final class LiveAudioEngine {
    private let engine = AVAudioEngine()
    private var tapState: TapState?
    private var currentURL: URL?

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

        return LiveRecording(url: url, buffers: buffers)
    }

    func stop() async -> URL? {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        tapState?.finish()
        let url = currentURL
        tapState = nil
        currentURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return url
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
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
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
