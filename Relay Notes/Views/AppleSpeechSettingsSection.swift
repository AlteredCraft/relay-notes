import Speech
import SwiftUI

/// Engine-specific Settings group for **Apple Speech**: the recognition preset
/// and contextual biasing. Shown only when `engine == .apple` (Approach C) so
/// these dials never appear as live no-ops under an engine that ignores them.
/// Binds straight to the `apple` bundle on `Tunings`, which persists the edits.
struct AppleSpeechSettingsSection: View {
    @Bindable var tunings: Tunings

    private let presets: [(label: String, value: SpeechTranscriber.Preset)] = [
        ("Transcription (basic)", .transcription),
        ("With Alternatives", .transcriptionWithAlternatives),
        ("Progressive (live)", .progressiveTranscription)
    ]

    var body: some View {
        Section {
            Picker("Preset", selection: $tunings.apple.preset) {
                ForEach(presets, id: \.value) { preset in
                    Text(preset.label).tag(preset.value)
                }
            }
        } header: {
            Text("Recognition")
        } footer: {
            Text("Basic is fastest and accurate. With Alternatives surfaces per-word alternates for a future tap-to-correct UX.")
        }

        Section {
            TextField("Words, comma-separated", text: $tunings.apple.contextualStringsText, axis: .vertical)
                .lineLimit(2...5)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Contextual biasing")
        } footer: {
            Text("Bias the recognizer toward specific words — names, jargon, proper nouns. Example: AlteredCraft, MLX, Qwen.")
        }
    }
}
