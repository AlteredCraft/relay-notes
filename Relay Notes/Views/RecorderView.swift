import AVFoundation
import Speech
import SwiftUI

struct RecorderView: View {
    let viewModel: RecorderViewModel

    var body: some View {
        VStack(spacing: 12) {
            transcriptArea
            statusText
            recordButton
            tuningSummary
        }
    }

    /// While recording, engines that stream partials (Apple) show the live
    /// transcript card; engines that don't (Whisper, which decodes once at
    /// finish) show a placeholder card instead of a perpetually blank one.
    @ViewBuilder
    private var transcriptArea: some View {
        switch viewModel.state {
        case .recording, .paused:
            if viewModel.emitsLivePartials {
                livePartialCard
            } else {
                whisperPlaceholderCard
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var livePartialCard: some View {
        if let partial = livePartial, !partial.isEmpty {
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

    private var whisperPlaceholderCard: some View {
        VStack(spacing: 10) {
            Text("Transcript will appear when you stop recording.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            AudioLevelMeter(level: viewModel.audioLevel)
                .padding(.horizontal, 24)
            Text(RecorderViewModel.formatElapsed(viewModel.elapsed))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .transition(.opacity)
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
        case .paused:
            Label("Paused — interrupted", systemImage: "pause.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
        case .finalizing:
            HStack(spacing: 8) {
                ProgressView()
                // For Whisper the decode happens here, so "Transcribing…" is the
                // honest label; Apple has already streamed its text and is just
                // closing out, so "Finalizing…".
                Text(viewModel.emitsLivePartials ? "Finalizing…" : "Transcribing…")
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
                case .recording, .paused:
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
        switch viewModel.state {
        case .recording, .paused: return true
        default: return false
        }
    }

    private var isFinalizing: Bool {
        viewModel.state == .finalizing
    }

    private var livePartial: String? {
        switch viewModel.state {
        case .recording(let partial), .paused(let partial): return partial
        default: return nil
        }
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

/// Horizontal level bar for the Whisper placeholder — fills proportionally to a
/// normalized 0...1 mic level so the user can see they're being heard while no
/// live transcript is available.
private struct AudioLevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(2, geometry.size.width * CGFloat(min(max(level, 0), 1))))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}
