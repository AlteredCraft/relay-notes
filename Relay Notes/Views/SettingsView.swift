import AVFoundation
import Speech
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Bindable var tunings: Tunings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private let modes: [(label: String, value: AVAudioSession.Mode)] = [
        ("Default", .default),
        ("Measurement (raw, no AGC)", .measurement),
        ("Voice Chat (VoIP)", .voiceChat),
        ("Video Recording", .videoRecording)
    ]

    private let bitrates: [Int] = [32_000, 64_000, 96_000, 128_000, 192_000]

    private let presets: [(label: String, value: SpeechTranscriber.Preset)] = [
        ("Transcription (basic)", .transcription),
        ("With Alternatives", .transcriptionWithAlternatives),
        ("Progressive (live)", .progressiveTranscription)
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $tunings.sessionMode) {
                        ForEach(modes, id: \.value) { mode in
                            Text(mode.label).tag(mode.value)
                        }
                    }
                    Picker("Bitrate", selection: $tunings.bitrate) {
                        ForEach(bitrates, id: \.self) { rate in
                            Text("\(rate / 1000) kbps").tag(rate)
                        }
                    }
                } header: {
                    Text("Audio session")
                } footer: {
                    Text("Default applies AGC and normal processing (recommended). Measurement disables both — useful for STT testing in quiet rooms but produces quieter playback.")
                }

                Section {
                    Picker("Preset", selection: $tunings.preset) {
                        ForEach(presets, id: \.value) { preset in
                            Text(preset.label).tag(preset.value)
                        }
                    }
                } header: {
                    Text("Transcription")
                } footer: {
                    Text("Basic is fastest and accurate. With Alternatives surfaces per-word alternates for a future tap-to-correct UX.")
                }

                Section {
                    TextField("Words, comma-separated", text: $tunings.contextualStringsText, axis: .vertical)
                        .lineLimit(2...5)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Contextual biasing")
                } footer: {
                    Text("Bias the recognizer toward specific words — names, jargon, proper nouns. Example: AlteredCraft, MLX, Qwen.")
                }

                #if DEBUG
                Section {
                    Button("Seed sample notes") {
                        SampleNotes.seed(into: modelContext)
                    }
                    Button("Delete all notes", role: .destructive) {
                        SampleNotes.deleteAll(in: modelContext)
                    }
                    Button("Reset tunings to defaults") {
                        tunings.resetToDefaults()
                    }
                } header: {
                    Text("Debug")
                } footer: {
                    Text("Debug-only — excluded from release builds.")
                }
                #endif
            }
            .navigationTitle("Tuning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView(tunings: Tunings())
        .modelContainer(for: Note.self, inMemory: true)
}
