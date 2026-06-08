import AVFoundation
import Speech
import SwiftUI

struct RecorderView: View {
    let viewModel: RecorderViewModel

    var body: some View {
        VStack(spacing: 12) {
            partialTranscript
            statusText
            recordButton
            tuningSummary
        }
    }

    @ViewBuilder
    private var partialTranscript: some View {
        if case .recording(let partial) = viewModel.state, !partial.isEmpty {
            ScrollView {
                Text(partial)
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .frame(maxHeight: 88)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
            .transition(.opacity)
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
        case .finalizing:
            HStack(spacing: 8) {
                ProgressView()
                Text("Finalizing…")
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
                case .finalizing:
                    return
                default:
                    await viewModel.startRecording()
                }
            }
        } label: {
            Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                .resizable()
                .frame(width: 80, height: 80)
                .foregroundStyle(isRecording ? Color.red : Color.accentColor)
        }
        .disabled(isFinalizing)
    }

    private var isRecording: Bool {
        if case .recording = viewModel.state { return true }
        return false
    }

    private var isFinalizing: Bool {
        viewModel.state == .finalizing
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
