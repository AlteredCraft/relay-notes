import AVFoundation
import Speech
import SwiftUI

struct RecorderView: View {
    let viewModel: RecorderViewModel

    var body: some View {
        VStack(spacing: 12) {
            statusText
            recordButton
            tuningSummary
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch viewModel.state {
        case .idle:
            Text("Tap to record")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .recording:
            Text("Recording…")
                .font(.subheadline)
                .foregroundStyle(.red)
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView()
                Text("Transcribing…")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        case .finished:
            Text("Saved")
                .font(.subheadline)
                .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }

    private var recordButton: some View {
        Button {
            Task {
                switch viewModel.state {
                case .recording:
                    await viewModel.stopAndTranscribe()
                case .transcribing:
                    return
                default:
                    await viewModel.startRecording()
                }
            }
        } label: {
            Image(systemName: viewModel.state == .recording ? "stop.circle.fill" : "mic.circle.fill")
                .resizable()
                .frame(width: 80, height: 80)
                .foregroundStyle(viewModel.state == .recording ? Color.red : Color.accentColor)
        }
        .disabled(viewModel.state == .transcribing)
    }

    private var tuningSummary: some View {
        Text("\(modeLabel(viewModel.tunings.sessionMode)) · \(viewModel.tunings.bitrate / 1000) kbps · \(presetLabel(viewModel.tunings.preset))")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private func modeLabel(_ mode: AVAudioSession.Mode) -> String {
        switch mode {
        case .default: "default"
        case .measurement: "measurement"
        case .voiceChat: "voiceChat"
        case .videoRecording: "videoRecording"
        default: mode.rawValue
        }
    }

    private func presetLabel(_ preset: SpeechTranscriber.Preset) -> String {
        if preset == .transcription { return "basic" }
        if preset == .transcriptionWithAlternatives { return "alts" }
        if preset == .progressiveTranscription { return "progressive" }
        return "custom"
    }
}
