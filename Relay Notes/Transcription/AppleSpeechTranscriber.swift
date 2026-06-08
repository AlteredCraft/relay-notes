import AVFoundation
import Foundation
import Speech

nonisolated final class AppleSpeechTranscriber: Transcriber {
    private let locale: Locale

    init(locale: Locale = .current) {
        self.locale = locale
    }

    func transcribe(_ audio: URL, options: TranscriptionOptions) async throws -> String {
        let authStatus = await Self.requestSpeechAuthorization()
        guard authStatus == .authorized else {
            throw TranscriptionError.notAuthorized
        }

        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.localeNotSupported(locale)
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: options.preset)

        do {
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await installation.downloadAndInstall()
            }
        } catch {
            throw TranscriptionError.assetInstallationFailed(error)
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: audio)
        } catch {
            throw TranscriptionError.audioOpenFailed(error)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        if !options.contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: options.contextualStrings]
            try? await analyzer.setContext(context)
        }

        let resultsTask = Task<String, any Error> {
            var combined = ""
            for try await result in transcriber.results {
                let segment = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !segment.isEmpty else { continue }
                if !combined.isEmpty { combined.append(" ") }
                combined.append(segment)
            }
            return combined
        }

        do {
            let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile)
            if let lastSampleTime {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            resultsTask.cancel()
            throw TranscriptionError.underlying(error)
        }

        let transcript = try await resultsTask.value

        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TranscriptionError.noSpeechDetected
        }
        return transcript
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
