import AVFoundation
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Bindable var tunings: Tunings
    let stores: ModelStores
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

                // Always shown — provisions each on-device model *before* it can be
                // selected (the engine rows above are disabled until ready). Both
                // reconcile after a delete so a deleted model can't back the
                // current engine selection.
                WhisperModelSection(store: stores.whisper) {
                    tunings.reconcileEngineAvailability(readyEngines: stores.readyEngines)
                }
                ParakeetModelSection(store: stores.parakeet) {
                    tunings.reconcileEngineAvailability(readyEngines: stores.readyEngines)
                }

                // The cleanup (LLM) model — not a transcription engine, so no
                // engine-availability reconcile; the per-note "Clean up" action
                // gates directly on this store's readiness.
                CleanupModelSection(store: stores.cleanup)

                // Cleanup personalization — domains + terms that bias the cleanup
                // model. Always shown (applies regardless of the selected engine).
                CleanupPersonalizationSection(tunings: tunings)

                // Engine-specific recognition settings swap with the selection
                // (Approach C) — no engine ever shows another engine's dials.
                switch tunings.engine {
                case .apple:
                    AppleSpeechSettingsSection(tunings: tunings)
                case .whisperMLX:
                    WhisperSettingsSection()
                case .parakeetMLX:
                    ParakeetSettingsSection()
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
            engineRow(.apple, title: "Apple Speech")
            engineRow(
                .whisperMLX,
                title: "On-device (Whisper)",
                subtitle: "Download the model below to enable",
                isEnabled: stores.isReady(.whisperMLX)
            )
            engineRow(
                .parakeetMLX,
                title: "On-device (Parakeet)",
                subtitle: "Download the model below to enable",
                isEnabled: stores.isReady(.parakeetMLX)
            )
        } header: {
            Text("Transcription engine")
        } footer: {
            Text("Apple Speech runs on-device with no model choice. The On-device engines (Whisper, Parakeet) transcribe locally via MLX — each becomes selectable once you download its model below.")
        }
    }

    /// One selectable engine row: title, an optional subtitle shown only while
    /// the engine is disabled (the "download the model" hint), and a trailing
    /// checkmark on the active engine. Tapping selects the engine.
    @ViewBuilder
    private func engineRow(
        _ engine: TranscriptionEngine,
        title: String,
        subtitle: String? = nil,
        isEnabled: Bool = true
    ) -> some View {
        Button {
            tunings.engine = engine
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                    if let subtitle, !isEnabled {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if tunings.engine == engine {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
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
            Button("Run cleanup smoke (console)") {
                Task.detached(priority: .userInitiated) {
                    await LLMCleanupSmoke.run()
                }
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
    SettingsView(tunings: Tunings(), stores: ModelStores())
        .modelContainer(for: Note.self, inMemory: true)
}
