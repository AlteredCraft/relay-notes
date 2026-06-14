import AVFoundation
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Bindable var tunings: Tunings
    let whisperStore: WhisperModelStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private let modes: [(label: String, value: AVAudioSession.Mode)] = [
        ("Default", .default),
        ("Measurement (raw, no AGC)", .measurement),
        ("Voice Chat (VoIP)", .voiceChat),
        ("Video Recording", .videoRecording)
    ]

    private let bitrates: [Int] = [32_000, 64_000, 96_000, 128_000, 192_000]

    var body: some View {
        NavigationStack {
            Form {
                engineSection

                // Always shown — provisions Whisper *before* it can be selected
                // (the engine row above is disabled until the model is ready).
                WhisperModelSection(store: whisperStore) {
                    tunings.reconcileEngineAvailability(whisperReady: false)
                }

                // Engine-specific recognition settings swap with the selection
                // (Approach C) — no engine ever shows another engine's dials.
                switch tunings.engine {
                case .apple:
                    AppleSpeechSettingsSection(tunings: tunings)
                case .whisperMLX:
                    WhisperSettingsSection()
                }

                // Shared — capture + storage apply regardless of engine.
                captureSection
                storageSection

                #if DEBUG
                debugSection
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

    private var engineSection: some View {
        Section {
            Button {
                tunings.engine = .apple
            } label: {
                HStack {
                    Text("Apple Speech")
                        .foregroundStyle(.primary)
                    Spacer()
                    if tunings.engine == .apple {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            let whisperReady = whisperStore.status == .ready
            Button {
                tunings.engine = .whisperMLX
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("On-device (Whisper)")
                            .foregroundStyle(whisperReady ? .primary : .secondary)
                        if !whisperReady {
                            Text("Download the model below to enable")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if tunings.engine == .whisperMLX {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!whisperReady)
        } header: {
            Text("Transcription engine")
        } footer: {
            Text("Apple Speech runs on-device with no model choice. On-device (Whisper) transcribes locally via MLX — it becomes selectable once you download its model below.")
        }
    }

    private var captureSection: some View {
        Section {
            Picker("Mode", selection: $tunings.sessionMode) {
                ForEach(modes, id: \.value) { mode in
                    Text(mode.label).tag(mode.value)
                }
            }
        } header: {
            Text("Capture")
        } footer: {
            Text("Shapes the microphone audio that both engines transcribe. Default applies AGC and normal processing (recommended). Measurement disables both — useful for STT testing in quiet rooms but produces quieter playback.")
        }
    }

    private var storageSection: some View {
        Section {
            Picker("Bitrate", selection: $tunings.bitrate) {
                ForEach(bitrates, id: \.self) { rate in
                    Text("\(rate / 1000) kbps").tag(rate)
                }
            }
        } header: {
            Text("Storage & playback")
        } footer: {
            Text("Sets the quality of the saved audio file you play back later. It does not affect transcription — both engines transcribe the live microphone signal, not the saved file.")
        }
    }

    #if DEBUG
    private var debugSection: some View {
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
            Button("Run MLX smoke (console)") {
                Task.detached(priority: .userInitiated) {
                    await MLXSmoke.run()
                }
            }
            Button("Run Parakeet smoke (console)") {
                Task.detached(priority: .userInitiated) {
                    await ParakeetSmoke.run()
                }
            }
            // Forces the next Parakeet smoke to re-download + SHA-256-verify the
            // 2.5 GB bundle (T2.2 fresh-download path). Until T2.5 ships the real
            // Parakeet model section, this is the only delete affordance.
            Button("Delete Parakeet model (force re-download)", role: .destructive) {
                try? ParakeetModelStore().delete()
            }
        } header: {
            Text("Debug")
        } footer: {
            Text("Debug-only — excluded from release builds. MLX smoke must run on the iPhone 15 Pro Max — the iOS Simulator does not support MLX/Metal.")
        }
    }
    #endif
}

#Preview {
    SettingsView(tunings: Tunings(), whisperStore: WhisperModelStore())
        .modelContainer(for: Note.self, inMemory: true)
}
