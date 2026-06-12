import AVFoundation
import Foundation
import Speech

nonisolated final class AppleSpeechTranscriber: Transcriber {
    private let locale: Locale

    init(locale: Locale = .current) {
        self.locale = locale
    }

    func transcribe(_ audio: URL, options: TranscriptionOptions) async throws -> String {
        guard case .apple(let appleOptions) = options else {
            preconditionFailure("AppleSpeechTranscriber received non-apple options — factory and engine selection are out of sync")
        }

        let authStatus = await Self.requestSpeechAuthorization()
        guard authStatus == .authorized else {
            throw TranscriptionError.notAuthorized
        }

        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.localeNotSupported(locale)
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: appleOptions.preset)

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

        if !appleOptions.contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: appleOptions.contextualStrings]
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

    func makeStreamingSession(options: TranscriptionOptions) async throws -> any TranscriptionSession {
        guard case .apple(let appleOptions) = options else {
            preconditionFailure("AppleSpeechTranscriber received non-apple options — factory and engine selection are out of sync")
        }

        let authStatus = await Self.requestSpeechAuthorization()
        guard authStatus == .authorized else {
            throw TranscriptionError.notAuthorized
        }

        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.localeNotSupported(locale)
        }

        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            transcriptionOptions: appleOptions.preset.transcriptionOptions,
            reportingOptions: appleOptions.preset.reportingOptions.union([.volatileResults]),
            attributeOptions: appleOptions.preset.attributeOptions
        )

        do {
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await installation.downloadAndInstall()
            }
        } catch {
            throw TranscriptionError.assetInstallationFailed(error)
        }

        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        if !appleOptions.contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: appleOptions.contextualStrings]
            try? await analyzer.setContext(context)
        }

        let (inputStream, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

        do {
            try await analyzer.start(inputSequence: inputStream)
        } catch {
            inputContinuation.finish()
            throw TranscriptionError.underlying(error)
        }

        return AppleSpeechSession(
            analyzer: analyzer,
            transcriber: transcriber,
            audioFormat: analyzerFormat,
            inputContinuation: inputContinuation
        )
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

private final class AppleSpeechSession: TranscriptionSession {
    let audioFormat: AVAudioFormat?
    let updates: AsyncStream<String>
    let emitsLivePartials = true
    var modelDescription: String { TranscriptionEngine.apple.displayName }

    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let updatesContinuation: AsyncStream<String>.Continuation
    private let resultsTask: Task<String, any Error>

    init(
        analyzer: SpeechAnalyzer,
        transcriber: SpeechTranscriber,
        audioFormat: AVAudioFormat?,
        inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.audioFormat = audioFormat
        self.inputContinuation = inputContinuation

        let (updatesStream, updatesContinuation) = AsyncStream.makeStream(of: String.self)
        self.updates = updatesStream
        self.updatesContinuation = updatesContinuation

        self.resultsTask = Task {
            var finalized = ""
            var lastVolatile = ""
            do {
                for try await result in transcriber.results {
                    let segment = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        if !segment.isEmpty {
                            if !finalized.isEmpty { finalized.append(" ") }
                            finalized.append(segment)
                        }
                        lastVolatile = ""
                        updatesContinuation.yield(finalized)
                    } else {
                        lastVolatile = segment
                        let live = finalized.isEmpty ? lastVolatile : finalized + " " + lastVolatile
                        updatesContinuation.yield(live)
                    }
                }
            } catch {
                updatesContinuation.finish()
                throw error
            }
            updatesContinuation.finish()
            return finalized
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        inputContinuation.yield(AnalyzerInput(buffer: buffer))
    }

    func finish() async throws -> String {
        inputContinuation.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
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

    func cancel() async {
        inputContinuation.finish()
        await analyzer.cancelAndFinishNow()
        resultsTask.cancel()
        updatesContinuation.finish()
    }
}
