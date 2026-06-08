import AVFoundation
import Foundation

struct RecordingOptions: Sendable {
    var format: AudioFormat = .m4aAAC
    var sessionMode: AVAudioSession.Mode = .measurement
    var bitrate: Int = 64_000
    var sampleRate: Double = 44_100
}

protocol AudioRecording: AnyObject, Sendable {
    func startRecording(options: RecordingOptions) async throws -> URL
    func stopRecording() async -> URL?
}

enum RecordingError: Error {
    case microphoneDenied
    case startFailed
    case sessionConfigurationFailed(any Error)
}

@MainActor
final class AudioRecorder: AudioRecording {
    private var recorder: AVAudioRecorder?
    private var currentURL: URL?

    func startRecording(options: RecordingOptions) async throws -> URL {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { throw RecordingError.microphoneDenied }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: options.sessionMode, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            throw RecordingError.sessionConfigurationFailed(error)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: options.format.formatID,
            AVSampleRateKey: options.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: options.bitrate,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        let filename = "\(UUID().uuidString).\(options.format.fileExtension)"
        let url = URL.documentsDirectory.appending(path: filename)

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.record() else {
            throw RecordingError.startFailed
        }
        self.recorder = recorder
        self.currentURL = url
        return url
    }

    func stopRecording() async -> URL? {
        recorder?.stop()
        let url = currentURL
        recorder = nil
        currentURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return url
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
